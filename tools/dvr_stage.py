# /// script
# requires-python = ">=3.11"
# ///
"""Stage the artifacts described by a DVR boot profile."""

from __future__ import annotations

import argparse
import hashlib
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

from dvr_config import (
    LocalSettings,
    Profile,
    ProfileError,
    load_local_settings,
    load_profile,
)


class StageFailure(Exception):
    def __init__(self, message: str, code: int = 3):
        super().__init__(message)
        self.code = code


def fail(message: str, code: int = 3) -> None:
    raise StageFailure(message, code)


def run(
    argv: tuple[str, ...],
    *,
    input_text: str | None = None,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def ssh(
    host: str,
    *command: str,
    input_text: str | None = None,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    return run(
        ("ssh", "-o", "BatchMode=yes", host, *command),
        input_text=input_text,
        capture=capture,
    )


def readable(path: Path, description: str) -> None:
    if not path.is_file() or not os.access(path, os.R_OK):
        fail(f"{description} is not readable: {path}", 2)


def checksum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    sidecar = Path(f"{path}.sha256")
    if sidecar.is_file():
        fields = sidecar.read_text(encoding="utf-8").split()
        if not fields or fields[0].lower() != actual:
            fail(f"checksum sidecar does not match artifact: {sidecar}", 2)
    return actual


def run_stream(
    argv: tuple[str, ...], source: Path
) -> subprocess.CompletedProcess[bytes]:
    with source.open("rb") as stream:
        return subprocess.run(argv, check=False, stdin=stream)


def remote_script(script: str, *args: str) -> str:
    command = f"sh -c {shlex.quote(script)} --"
    return " ".join((command, *(shlex.quote(arg) for arg in args)))


def check_pi(host: str, profile: Profile, *, start_tftp: bool) -> None:
    console_check = (
        "if grep -q '^ttyAMA0' /proc/consoles; then "
        "echo 'error: ttyAMA0 is a Pi console'; exit 1; fi"
    )
    if ssh(host, console_check).returncode:
        fail("Pi UART preflight failed")

    if profile.kernel and profile.kernel.source == "tftp":
        command = (
            "sudo systemctl start tftpd-hpa && systemctl is-active --quiet tftpd-hpa"
            if start_tftp
            else "systemctl is-active --quiet tftpd-hpa"
        )
        if ssh(host, command).returncode:
            fail("tftpd-hpa is not active")


USB_CHECK = r"""
set -eu

tr '\000' '\n' < /proc/device-tree/compatible | grep -qx 'tvt,dhb-ax' || {
	echo 'dvr-stage: the target is not the DHB_AX board' >&2
	exit 1
}
boot_part=$(blkid -t 'LABEL=DHBAXBOOT' -o device)
[ -b "$boot_part" ] || {
	echo 'dvr-stage: USB boot partition not found' >&2
	exit 1
}
grep -q "^$boot_part " /proc/mounts && {
	echo "dvr-stage: $boot_part is already mounted" >&2
	exit 1
}
grep -q "^$boot_part " /proc/swaps 2>/dev/null && {
	echo "dvr-stage: $boot_part is active swap" >&2
	exit 1
}
:
"""


HDD_CHECK = r"""
set -eu

partuuid=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
label=$2
[ "$(hostname)" = minimal ] || {
	echo 'dvr-stage: the DVR is not the minimal initramfs' >&2
	exit 1
}
awk '$2 == "/" && $3 == "rootfs" { found = 1 }
	END { exit !found }' /proc/mounts || {
	echo 'dvr-stage: the DVR root is not the minimal initramfs' >&2
	exit 1
}
root_part=$(blkid -t "PARTUUID=$partuuid" -o device)
[ -b "$root_part" ] || {
	echo 'dvr-stage: HDD root partition not found' >&2
	exit 1
}
actual_label=$(blkid -s LABEL -o value "$root_part")
[ "$actual_label" = "$label" ] || {
	echo "dvr-stage: $root_part label is '$actual_label', expected '$label'" >&2
	exit 1
}
grep -q "^$root_part " /proc/mounts && {
	echo "dvr-stage: $root_part is already mounted" >&2
	exit 1
}
grep -q "^$root_part " /proc/swaps 2>/dev/null && {
	echo "dvr-stage: $root_part is active swap" >&2
	exit 1
}
:
"""


NFS_GUARD = r"""
set -eu

dvr_ipaddr=$1
dvr_ipaddr_pattern=$(printf '%s\n' "$dvr_ipaddr" | sed 's/\./\\./g')
if ss -Htn state established '( sport = :2049 )' 2>/dev/null |
	grep -Eq "${dvr_ipaddr_pattern}:[0-9]+"; then
	echo 'dvr-stage: DVR has an active NFS session' >&2
	echo 'boot the minimal image before publishing a complete rootfs' >&2
	exit 1
fi
"""


def check_usb(dvr_ipaddr: str) -> None:
    if ssh(f"root@{dvr_ipaddr}", "sh", "-s", input_text=USB_CHECK).returncode:
        fail("USB kernel staging preflight failed")


def check_hdd_root(profile: Profile, dvr_ipaddr: str) -> None:
    assert profile.rootfs and profile.rootfs.partuuid and profile.rootfs.label
    if ssh(
        f"root@{dvr_ipaddr}",
        "sh",
        "-s",
        "--",
        profile.rootfs.partuuid,
        profile.rootfs.label,
        input_text=HDD_CHECK,
    ).returncode:
        fail("HDD-root staging preflight failed")


def check_nfs_root(profile: Profile, settings: LocalSettings) -> None:
    if ssh(
        settings.pi_ipaddr,
        "sudo",
        "sh",
        "-s",
        "--",
        settings.dvr_ipaddr,
        input_text=NFS_GUARD,
    ).returncode:
        fail("NFS-root staging preflight failed")


def preflight(
    profile: Profile,
    settings: LocalSettings,
    *,
    kernel_only: bool,
    check: bool,
) -> None:
    if profile.boot.action == "prompt":
        return
    assert profile.kernel and profile.rootfs
    readable(profile.kernel.artifact, "kernel artifact")
    if not kernel_only and profile.rootfs.artifact:
        readable(profile.rootfs.artifact, "root filesystem artifact")

    needs_pi = profile.kernel.source == "tftp" or (
        not kernel_only and profile.rootfs.type == "nfs"
    )
    if needs_pi:
        check_pi(settings.pi_ipaddr, profile, start_tftp=not check)
    if profile.kernel.source == "usb":
        check_usb(settings.dvr_ipaddr)
    if not kernel_only and profile.rootfs.type == "hdd":
        check_hdd_root(profile, settings.dvr_ipaddr)
    if not kernel_only and profile.rootfs.type == "nfs":
        check_nfs_root(profile, settings)


def stage_tftp_kernel(profile: Profile, pi_ipaddr: str) -> None:
    assert profile.kernel
    host = pi_ipaddr
    target = profile.kernel.target
    temporary = f"/tmp/dvr-stage-{os.getpid()}-{target}"
    incoming = f"/srv/tftp/.dvr-stage-{os.getpid()}-{target}.incoming"
    expected = checksum(profile.kernel.artifact)
    print(f"Staging {profile.kernel.artifact} on {host}:/srv/tftp/{target}...")
    if run(
        (
            "scp",
            "-q",
            "-o",
            "BatchMode=yes",
            "--",
            str(profile.kernel.artifact),
            f"{host}:{temporary}",
        )
    ).returncode:
        fail(f"could not copy the kernel to {host}")
    command = (
        f"test \"$(sha256sum {temporary} | awk '{{print $1}}')\" = {expected} && "
        f"sudo install -m0644 {temporary} {incoming} && "
        f"test \"$(sha256sum {incoming} | awk '{{print $1}}')\" = {expected} && "
        f"sudo mv -f {incoming} /srv/tftp/{target}"
    )
    if ssh(host, command).returncode:
        ssh(host, f"sudo rm -f {temporary} {incoming}")
        fail("could not install the kernel beneath /srv/tftp")
    ssh(host, f"rm -f {temporary}")


USB_INSTALL = r"""
set -eu

uimage=$1
kernel_name=$2
expected=$3
boot_mount=/mnt/dhb-ax-boot

cleanup()
{
	sync
	grep -q " $boot_mount " /proc/mounts && umount "$boot_mount" || true
	rm -f "$uimage"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

boot_part=$(blkid -t 'LABEL=DHBAXBOOT' -o device)
[ "$(sha256sum "$uimage" | awk '{ print $1 }')" = "$expected" ] || {
	echo 'dvr-stage: staged kernel checksum mismatch' >&2
	exit 1
}

mkdir -p "$boot_mount"
modprobe vfat 2>/dev/null || true
mount -t vfat "$boot_part" "$boot_mount"
rm -f "$boot_mount/$kernel_name.new"
cp "$uimage" "$boot_mount/$kernel_name.new"
sync
[ "$(sha256sum "$boot_mount/$kernel_name.new" | awk '{ print $1 }')" = "$expected" ] || {
	echo 'dvr-stage: USB kernel checksum mismatch' >&2
	exit 1
}
mv -f "$boot_mount/$kernel_name.new" "$boot_mount/$kernel_name"
rm -f "$boot_mount/$kernel_name.sha256"
sync
echo "Installed kernel on $boot_part as /$kernel_name"
"""


def stage_usb_kernel(profile: Profile, dvr_ipaddr: str) -> None:
    assert profile.kernel
    host = f"root@{dvr_ipaddr}"
    temporary = f"/tmp/dvr-stage-{os.getpid()}-{profile.kernel.target}"
    expected = checksum(profile.kernel.artifact)
    print(f"Staging {profile.kernel.artifact} on {host} USB...")
    if run(
        (
            "scp",
            "-q",
            "-o",
            "BatchMode=yes",
            "--",
            str(profile.kernel.artifact),
            f"{host}:{temporary}",
        )
    ).returncode:
        fail(f"could not copy the kernel to {host}")
    if ssh(
        host,
        "sh",
        "-s",
        "--",
        temporary,
        profile.kernel.target,
        expected,
        input_text=USB_INSTALL,
    ).returncode:
        ssh(host, "rm", "-f", temporary)
        fail("could not install the USB kernel")


HDD_INSTALL = r"""
set -eu

partuuid=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
label=$2
os_id=$3
kernel_release=$4
expected=$5
host_epoch=$6
root_mount=/mnt/dhb-ax-root
hash_fifo=/tmp/dvr-stage-hash.$$
hash_result=/tmp/dvr-stage-hash-result.$$

cleanup()
{
	sync
	grep -q " $root_mount " /proc/mounts && umount "$root_mount" || true
	rm -f "$hash_fifo" "$hash_result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

root_part=$(blkid -t "PARTUUID=$partuuid" -o device)
date -u -s "@$host_epoch" >/dev/null

echo "Formatting $root_part as $label..."
mke2fs -F -t ext4 -L "$label" -m 0 "$root_part"
mkdir -p "$root_mount"
mount -t ext4 "$root_part" "$root_mount"
mkfifo "$hash_fifo"
sha256sum < "$hash_fifo" > "$hash_result" &
hasher=$!
tee "$hash_fifo" |
	tar --numeric-owner --acls --xattrs --xattrs-include='*' \
		-xpf - -C "$root_mount"
wait "$hasher"
actual=$(awk '{ print $1 }' "$hash_result")
[ "$actual" = "$expected" ] || {
	echo "dvr-stage: rootfs stream checksum mismatch" >&2
	exit 1
}
[ -x "$root_mount/sbin/init" ] || {
	echo 'dvr-stage: installed rootfs has no executable /sbin/init' >&2
	exit 1
}
installed_id=$(sed -n 's/^ID=//p' "$root_mount/etc/os-release" | tr -d '"')
[ "$installed_id" = "$os_id" ] || {
	echo "dvr-stage: installed OS is '$installed_id', expected '$os_id'" >&2
	exit 1
}
[ -d "$root_mount/lib/modules/$kernel_release" ] || {
	echo "dvr-stage: installed rootfs lacks modules for $kernel_release" >&2
	exit 1
}
sync
umount "$root_mount"
echo "Installed $os_id rootfs on $root_part (PARTUUID=$partuuid, LABEL=$label)"
"""


def stage_hdd_root(profile: Profile, dvr_ipaddr: str) -> None:
    assert (
        profile.rootfs
        and profile.rootfs.artifact
        and profile.rootfs.partuuid
        and profile.rootfs.label
        and profile.rootfs.os_id
        and profile.rootfs.kernel_release
    )
    host = f"root@{dvr_ipaddr}"
    expected = checksum(profile.rootfs.artifact)
    print(f"Staging {profile.rootfs.artifact} on {host} HDD...")
    command = remote_script(
        HDD_INSTALL,
        profile.rootfs.partuuid,
        profile.rootfs.label,
        profile.rootfs.os_id,
        profile.rootfs.kernel_release,
        expected,
        str(int(time.time())),
    )
    if run_stream(
        ("ssh", "-o", "BatchMode=yes", host, command), profile.rootfs.artifact
    ).returncode:
        fail("could not install the HDD root filesystem")


NFS_INSTALL = r"""
set -eu

export_path=$1
archive=$2
expected=$3
os_id=$4
kernel_release=$5

parent=${export_path%/*}
incoming=$export_path.incoming.$$
previous=$export_path.previous.$$
cleanup()
{
	rm -f -- "$archive"
	rm -rf -- "$incoming"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ "$(sha256sum "$archive" | awk '{ print $1 }')" = "$expected" ] || {
	echo 'dvr-stage: NFS rootfs checksum mismatch' >&2
	exit 1
}
mkdir -p "$parent"
rm -rf -- "$incoming" "$previous"
mkdir -m 0755 "$incoming"
tar --numeric-owner --acls --xattrs --xattrs-include='*' \
	-xpf "$archive" -C "$incoming"
[ -x "$incoming/sbin/init" ] || {
	echo 'dvr-stage: NFS root has no executable /sbin/init' >&2
	exit 1
}
installed_id=$(sed -n 's/^ID=//p' "$incoming/etc/os-release" | tr -d '"')
[ "$installed_id" = "$os_id" ] || {
	echo "dvr-stage: NFS root OS is '$installed_id', expected '$os_id'" >&2
	exit 1
}
[ -d "$incoming/lib/modules/$kernel_release" ] || {
	echo "dvr-stage: NFS root lacks modules for $kernel_release" >&2
	exit 1
}
[ ! -e "$export_path" ] || mv "$export_path" "$previous"
if ! mv "$incoming" "$export_path"; then
	[ ! -e "$previous" ] || mv "$previous" "$export_path"
	exit 1
fi
rm -rf -- "$previous"
sync
echo "Published NFS root at $export_path"
"""


def stage_nfs_root(profile: Profile, pi_ipaddr: str) -> None:
    assert (
        profile.rootfs
        and profile.rootfs.artifact
        and profile.rootfs.export
        and profile.rootfs.os_id
        and profile.rootfs.kernel_release
    )
    host = pi_ipaddr
    remote_archive = f"/tmp/dvr-stage-rootfs-{os.getpid()}.tar"
    expected = checksum(profile.rootfs.artifact)
    print(
        f"Publishing {profile.rootfs.artifact} to "
        f"{host}:{profile.rootfs.export}..."
    )
    if run(
        (
            "scp",
            "-q",
            "-o",
            "BatchMode=yes",
            "--",
            str(profile.rootfs.artifact),
            f"{host}:{remote_archive}",
        )
    ).returncode:
        fail(f"could not copy the root filesystem to {host}")
    if ssh(
        host,
        "sudo",
        "sh",
        "-s",
        "--",
        profile.rootfs.export,
        remote_archive,
        expected,
        profile.rootfs.os_id,
        profile.rootfs.kernel_release,
        input_text=NFS_INSTALL,
    ).returncode:
        ssh(host, "rm", "-f", remote_archive)
        fail("could not publish the NFS root filesystem")


def stage_rootfs(profile: Profile, settings: LocalSettings) -> None:
    if profile.rootfs.type == "hdd":
        stage_hdd_root(profile, settings.dvr_ipaddr)
    elif profile.rootfs.type == "nfs":
        stage_nfs_root(profile, settings.pi_ipaddr)


def stage_kernel(profile: Profile, settings: LocalSettings) -> None:
    if profile.kernel.source == "usb":
        stage_usb_kernel(profile, settings.dvr_ipaddr)
    else:
        stage_tftp_kernel(profile, settings.pi_ipaddr)


def stage(
    profile: Profile, settings: LocalSettings, *, kernel_only: bool
) -> None:
    if profile.boot.action == "prompt":
        print(f"Profile '{profile.name}' has no artifacts to stage.")
        return
    assert profile.kernel and profile.rootfs
    if not kernel_only:
        stage_rootfs(profile, settings)
    stage_kernel(profile, settings)
    print(f"Profile '{profile.name}' staged successfully.")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="dvr-stage.sh",
        description="Stage the artifacts described by a DVR boot profile.",
    )
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--kernel-only", action="store_true")
    parser.add_argument("profile")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        settings = load_local_settings()
        profile = load_profile(args.profile, local_settings=settings)
        preflight(
            profile, settings, kernel_only=args.kernel_only, check=args.check
        )
        if args.check:
            print(f"Profile '{profile.name}' staging preflight passed.")
            return 0
        stage(profile, settings, kernel_only=args.kernel_only)
        return 0
    except (ProfileError, StageFailure) as error:
        code = error.code if isinstance(error, StageFailure) else 2
        print(f"error: {error}", file=sys.stderr)
        return code
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
