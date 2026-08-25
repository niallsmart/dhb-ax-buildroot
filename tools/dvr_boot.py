# /// script
# requires-python = ">=3.11"
# dependencies = ["pexpect==4.9.0"]
# ///
"""Boot the DVR through the persistent tmux console using Pexpect."""

import argparse
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

import pexpect
from pexpect.fdpexpect import fdspawn

from dvr_config import LocalSettings, ProfileError, load_local_settings, load_profile

TMUX_SESSION = "dvr"
VENDOR_PASSWORD = "1001chin"


class BootFailure(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def fail(message, code):
    raise BootFailure(message, code)


def run(argv, *, input_text=None, capture=False):
    return subprocess.run(
        argv,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def tmux(*args, input_text=None, capture=False):
    return run(("tmux", *args), input_text=input_text, capture=capture)


def ssh(host, command, capture=False):
    return run(("ssh", "-o", "BatchMode=yes", host, command), capture=capture)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="dvr-boot.sh",
        description="Execute a named DVR boot profile through the tmux console.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument(
        "--status",
        action="store_true",
        help="report the current console state without booting",
    )
    parser.add_argument("--transcript")
    parser.add_argument("profile", nargs="?")
    args = parser.parse_args(argv)
    if args.status and args.profile:
        parser.error("--status does not accept a profile")
    if not args.status and not args.profile:
        parser.error("a profile is required unless --status is used")
    return args


def preflight(profile, settings: LocalSettings):
    if profile is None:
        target = "DVR console state"
    elif profile.kernel:
        target = (
            f"USB {profile.kernel.usb_device}/{profile.kernel.target}"
            if profile.kernel.source == "usb"
            else f"{settings.pi_ipaddr}:/srv/tftp/{profile.kernel.target}"
        )
    else:
        target = "U-Boot prompt"
    print(f"Preflight: {target}")
    check_console = (
        "if grep -q '^ttyAMA0' /proc/consoles; then "
        "echo 'error: ttyAMA0 is a Pi console'; exit 1; fi"
    )
    if ssh(settings.pi_ipaddr, check_console).returncode:
        fail("Pi UART preflight failed", 3)

    if (
        profile
        and profile.kernel
        and profile.kernel.source == "tftp"
        and ssh(
            settings.pi_ipaddr,
            "systemctl is-active --quiet tftpd-hpa",
        ).returncode
    ):
        fail("tftpd-hpa is not active", 3)

    if tmux("has-session", "-t", TMUX_SESSION, capture=True).returncode:
        fail(
            f"no tmux session '{TMUX_SESSION}'; start it with: just dvr-console",
            3,
        )
    pane = tmux(
        "display-message",
        "-p",
        "-t",
        TMUX_SESSION,
        "#{pane_current_command} #{pane_dead}",
        capture=True,
    )
    if pane.returncode or pane.stdout.strip() != "ssh 0":
        fail(
            f"tmux session '{TMUX_SESSION}' is not a live SSH console "
            f"({pane.stdout.strip()})",
            3,
        )

    if (
        profile
        and profile.kernel
        and profile.kernel.source == "tftp"
        and ssh(
            settings.pi_ipaddr,
            f"test -r /srv/tftp/{profile.kernel.target}",
        ).returncode
    ):
        fail(
            f"kernel is not readable beneath /srv/tftp: {profile.kernel.target}",
            3,
        )


CSI = r"(?:\x1b\[[0-?]*[ -/]*[@-~])*"
LINE_START = rf"(?m)^\r*{CSI}"
UBOOT_PROMPT = rf"{LINE_START}hisilicon # *{CSI}\r*$"
SHELL_PROMPT = (
    rf"{LINE_START}(?:(?:~|/) |root@[^:\r\n]+:[^#\r\n]*)?# *{CSI}\r*$"
)


class Console:
    def __init__(self, session, transcript=None):
        self.session = session
        self.lock = Path(f"/tmp/dvr-tmux-{session}.lock")
        self.fifo = self.lock / "console.fifo"
        self.transcript_path = transcript
        self.transcript = None
        self.fifo_fd = None
        self.expecter = None
        self.pipe_enabled = False

    def open(self):
        try:
            self.lock.mkdir()
        except FileExistsError:
            fail(f"another DVR console tool holds {self.lock}", 4)
        try:
            if self.transcript_path:
                self.transcript = open(  # noqa: SIM115 - closed by close()
                    self.transcript_path,
                    "a",
                    encoding="utf-8",
                    errors="replace",
                )
            os.mkfifo(self.fifo, 0o600)
            self.fifo_fd = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
            pane_pipe = tmux(
                "display-message",
                "-p",
                "-t",
                self.session,
                "#{pane_pipe}",
                capture=True,
            )
            if pane_pipe.returncode:
                fail("could not inspect the tmux pane", 4)
            if pane_pipe.stdout.strip() == "1":
                fail(f"tmux session '{self.session}' already has a pane pipe", 4)
            pipe_command = f"exec cat >> {shlex.quote(str(self.fifo))}"
            if tmux(
                "pipe-pane", "-t", self.session, pipe_command, capture=True
            ).returncode:
                fail("could not enable tmux pipe-pane", 4)
            self.pipe_enabled = True
            self.expecter = fdspawn(
                self.fifo_fd,
                encoding="utf-8",
                codec_errors="replace",
                maxread=65536,
                searchwindowsize=200000,
            )
            self.expecter.logfile_read = self.transcript
        except Exception:
            self.close()
            raise

    def close(self):
        if self.pipe_enabled:
            tmux("pipe-pane", "-t", self.session, capture=True)
            self.pipe_enabled = False
        if self.expecter:
            self.expecter.close()
            self.expecter = None
        if self.fifo_fd is not None:
            try:
                os.close(self.fifo_fd)
            except OSError:
                pass
            self.fifo_fd = None
        if self.transcript:
            self.transcript.close()
            self.transcript = None
        try:
            self.fifo.unlink()
            self.lock.rmdir()
        except OSError:
            pass

    def send(self, text):
        enter = text.endswith("\r")
        text = text.removesuffix("\r")
        if (
            text
            and tmux(
                "send-keys", "-t", self.session, "-l", "--", text, capture=True
            ).returncode
        ):
            fail("could not send keys through tmux", 4)
        if (
            enter
            and tmux("send-keys", "-t", self.session, "Enter", capture=True).returncode
        ):
            fail("could not send Enter through tmux", 4)

    def send_secret(self, text):
        buffer_name = f"dvr-console-secret-{os.getpid()}"
        if tmux("load-buffer", "-b", buffer_name, "-", input_text=text).returncode:
            fail("could not load private console input into tmux", 4)
        try:
            if tmux(
                "paste-buffer",
                "-d",
                "-b",
                buffer_name,
                "-t",
                self.session,
                capture=True,
            ).returncode:
                fail("could not send private console input through tmux", 4)
            if tmux(
                "send-keys", "-t", self.session, "Enter", capture=True
            ).returncode:
                fail("could not send Enter through tmux", 4)
        finally:
            tmux("delete-buffer", "-b", buffer_name, capture=True)

    def wait(self, cases, timeout):
        patterns = [pattern for _, pattern in cases]
        selected = self.expecter.expect(
            patterns + [pexpect.TIMEOUT, pexpect.EOF], timeout=timeout
        )
        if selected < len(cases):
            return cases[selected][0], self.expecter.before
        if selected == len(cases):
            return "timeout", self.expecter.before
        fail("tmux console stream closed unexpectedly", 4)


def run_uboot_command(console, command, timeout=10):
    # The board sometimes loses the first character after autoboot. A leading
    # space can be sacrificed without changing the U-Boot command.
    console.send(f" {command}\r")
    state, _ = console.wait((("echo", rf"{re.escape(command)}\r*\n"),), timeout)
    if state != "echo":
        fail(f"U-Boot did not echo command: {command}", 7)
    state, output = console.wait((("uboot", UBOOT_PROMPT),), timeout)
    if state != "uboot":
        fail(f"U-Boot command timed out: {command}", 7)
    return output


def identify_console(console):
    console.send("\r")
    cases = (
        ("uboot", UBOOT_PROMPT),
        ("shell", SHELL_PROMPT),
        ("vendor_login", r"(?m)^\r*\(none\) login: *\r*$"),
        ("main_login", r"(?m)^\r*dhb-ax login: *\r*$"),
        ("debian_login", r"(?m)^\r*dhb-ax-debian login: *\r*$"),
        ("minimal_login", r"(?m)^\r*minimal login: *\r*$"),
        ("password", r"(?m)^\r*Password: *\r*$"),
    )
    for _ in range(12):
        state, _ = console.wait(cases, 5)
        if state in (
            "uboot",
            "shell",
            "vendor_login",
            "main_login",
            "debian_login",
            "minimal_login",
        ):
            return state
        console.send("\r")
    fail("could not identify the current DVR console state", 5)


def report_status(console):
    descriptions = {
        "uboot": "U-Boot prompt",
        "shell": "Linux shell prompt",
        "vendor_login": "vendor Linux login prompt",
        "main_login": "main Buildroot login prompt",
        "debian_login": "Debian login prompt",
        "minimal_login": "minimal Buildroot login prompt",
    }
    print(f"Current DVR state: {descriptions[identify_console(console)]}.")


def login(console, password):
    console.send("root\r")
    state, _ = console.wait(
        (
            ("password", r"(?m)^\r*Password: *\r*$"),
            ("shell", SHELL_PROMPT),
        ),
        10,
    )
    if state == "shell":
        return
    if state != "password":
        fail("Linux console did not request a password", 5)

    console.send_secret(password)
    state, _ = console.wait(
        (
            ("shell", SHELL_PROMPT),
            ("failure", r"(?m)^\r*Login incorrect\s*\r*$"),
        ),
        10,
    )
    if state != "shell":
        fail("Linux console login failed", 5)


def reach_uboot(settings: LocalSettings, console):
    state = identify_console(console)
    if state == "uboot":
        return

    if state == "vendor_login":
        print("Logging in to vendor Linux through the serial console...")
        login(console, VENDOR_PASSWORD)
    elif state in ("main_login", "debian_login", "minimal_login"):
        print(
            "Logging in to the maintained Linux system through the serial console..."
        )
        login(console, settings.root_password)

    print("Rebooting and interrupting autoboot...")
    console.send("reboot\r")

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        console.send(" ")
        state, _ = console.wait((("uboot", UBOOT_PROMPT),), 0.25)
        if state == "uboot":
            return
    fail("clean reboot did not reach the U-Boot prompt within 60 seconds", 6)


def configure_bootargs(profile, console):
    expected = profile.boot.bootargs
    print(f"Configuring temporary {profile.rootfs.type}-root bootargs...")
    first, *remaining = profile.boot.args
    run_uboot_command(console, f"setenv bootargs {first}")
    for argument in remaining:
        run_uboot_command(console, f"setenv bootargs ${{bootargs}} {argument}")
    output = run_uboot_command(console, "printenv bootargs")
    values = re.findall(r"(?m)^\r*bootargs=(.*?)\r*(?:\n|$)", output)
    actual = values[-1] if values else ""
    if actual != expected:
        fail(f"U-Boot bootargs mismatch: expected '{expected}', got '{actual}'", 7)
    print("Verified U-Boot bootargs.")


def require_uboot_prompt(console, message):
    state, _ = console.wait((("uboot", UBOOT_PROMPT),), 10)
    if state != "uboot":
        fail(message, 8)


def load_usb(profile, console):
    kernel = profile.kernel
    print("Scanning USB storage...")
    run_uboot_command(console, "usb reset")
    print(f"Loading USB {kernel.usb_device}/{kernel.target}...")
    console.send(
        f" fatload usb {kernel.usb_device} {kernel.load_address} {kernel.target}\r"
    )
    state, _ = console.wait(
        (
            ("success", r"[0-9]+ bytes read"),
            (
                "failure",
                (
                    r"Bad device|Unable to read|no USB devices available|"
                    r"\*\* Invalid partition"
                ),
            ),
        ),
        120,
    )
    if state == "failure":
        fail("USB FAT load reported a failure", 8)
    if state != "success":
        fail("USB FAT load timed out", 8)
    require_uboot_prompt(console, "U-Boot prompt did not return after USB load")


def configure_uboot_network(settings, console):
    print("Configuring temporary U-Boot networking...")
    values = (
        ("ipaddr", settings.dvr_ipaddr),
        ("netmask", settings.dvr_netmask),
        ("serverip", settings.pi_ipaddr),
        ("ethaddr", settings.dvr_ethaddr),
    )
    for name, value in values:
        run_uboot_command(console, f"setenv {name} {value}")


def recover_phy(console):
    print("Reinitializing the PHY before retrying TFTP...")
    run_uboot_command(console, "mii write 1 e 0")
    run_uboot_command(console, "mii write 1 0 1140")
    time.sleep(30)


def load_tftp(profile, settings, console):
    kernel = profile.kernel
    configure_uboot_network(settings, console)
    command = f"tftp {kernel.load_address} {kernel.target}"

    for attempt in range(3):
        print(f"Loading {kernel.target}...")
        console.send(f" {command}\r")
        state, _ = console.wait(
            (
                ("success", r"Bytes transferred = [0-9]+"),
                (
                    "failure",
                    (
                        r"TFTP error|Retry count exceeded|Access violation|"
                        r"File not found"
                    ),
                ),
                ("phy", r"PHY not link!"),
            ),
            120,
        )
        if state == "success":
            require_uboot_prompt(console, "U-Boot prompt did not return after TFTP")
            return
        if state == "failure":
            fail("TFTP transfer failed", 8)
        if state == "timeout":
            fail("TFTP timed out", 8)

        require_uboot_prompt(console, "U-Boot prompt did not return after PHY failure")
        if attempt == 2:
            fail("Ethernet PHY is still down; hard-reset the DVR and retry", 8)
        if attempt == 0:
            recover_phy(console)
        else:
            print("PHY is still negotiating; waiting before one final TFTP retry...")
            time.sleep(10)


def load_image(profile, settings, console):
    if profile.kernel.source == "usb":
        load_usb(profile, console)
    else:
        load_tftp(profile, settings, console)


def boot(profile, settings: LocalSettings, console):
    reach_uboot(settings, console)
    if profile.boot.action == "prompt":
        print("U-Boot prompt reached successfully.")
        return

    configure_bootargs(profile, console)
    load_image(profile, settings, console)
    print("Booting from RAM...")
    console.send(f" bootm {profile.kernel.load_address}\r")
    state, _ = console.wait(
        (
            (
                "login",
                rf"(?m)^\r*{re.escape(profile.boot.hostname)} login: *\r*$",
            ),
            ("panic", r"Kernel panic - not syncing"),
            ("overlap", r"kernel image will overwrite uboot"),
            ("reset", r"(?m)^\r*U-Boot 2010\.06"),
        ),
        profile.boot.timeout,
    )
    errors = {
        "panic": "kernel panic",
        "overlap": "kernel payload overlaps vendor U-Boot",
        "reset": "board reset before the Linux login prompt",
        "timeout": "Linux login prompt did not appear before the timeout",
    }
    if state != "login":
        fail(errors[state], 9)
    print("Expected Linux login prompt reached successfully.")


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    console = None
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        settings = load_local_settings()
        profile = (
            None
            if args.status
            else load_profile(args.profile, local_settings=settings)
        )
        preflight(profile, settings)
        if args.check:
            print("Preflight passed; the UART was not accessed.")
            return 0
        console = Console(TMUX_SESSION, args.transcript)
        console.open()
        if args.status:
            report_status(console)
            return 0
        boot(profile, settings, console)
        return 0
    except (BootFailure, ProfileError) as error:
        print(f"error: {error}", file=sys.stderr)
        return error.code if isinstance(error, BootFailure) else 2
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130
    finally:
        if console:
            console.close()


if __name__ == "__main__":
    for caught_signal in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(caught_signal, interrupted)
    raise SystemExit(main())
