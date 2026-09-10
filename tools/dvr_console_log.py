"""Maintain the shared log for the persistent DVR tmux console."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

TMUX_SESSION = "dvr"
LOG_OPTION = "@dvr_console_log"


class ConsoleLogError(RuntimeError):
    """The shared console log could not be configured."""


def repository_root() -> Path:
    return Path(
        os.environ.get("DVR_BOOT_REPO_ROOT", Path(__file__).resolve().parents[1])
    )


def console_log_path() -> Path:
    return repository_root() / "logs" / "dvr-console.log"


def _tmux(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ("tmux", *args),
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def _tmux_sequence(
    *commands: tuple[str, ...],
) -> subprocess.CompletedProcess[str]:
    arguments: list[str] = []
    for command in commands:
        if arguments:
            arguments.append(";")
        arguments.extend(command)
    return _tmux(*arguments)


def _tmux_value(session: str, value: str) -> str:
    result = _tmux("display-message", "-p", "-t", session, value)
    if result.returncode:
        raise ConsoleLogError(result.stdout.strip() or "could not inspect tmux")
    return result.stdout.strip()


def _log_option(session: str) -> str:
    result = _tmux("show-options", "-qv", "-t", session, LOG_OPTION)
    if result.returncode:
        raise ConsoleLogError(result.stdout.strip() or "could not inspect tmux")
    return result.stdout.strip()


def _create_private_log(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.close(descriptor)
    path.chmod(0o600)


def ensure_console_log(session: str = TMUX_SESSION) -> Path:
    """Ensure the session has one persistent pipe writing to its shared log."""
    if _tmux("has-session", "-t", session).returncode:
        raise ConsoleLogError(
            f"no tmux session '{session}'; start it with: just dvr-console"
        )

    path = console_log_path()
    marker = _log_option(session)
    pane_pipe = _tmux_value(session, "#{pane_pipe}")
    if pane_pipe not in ("0", "1"):
        raise ConsoleLogError(f"unexpected tmux pane_pipe value: {pane_pipe}")

    if pane_pipe == "1":
        if marker != str(path):
            raise ConsoleLogError(
                f"tmux session '{session}' already has an unmanaged pane pipe"
            )
        if not path.is_file():
            raise ConsoleLogError(f"active tmux console log is missing: {path}")
        path.chmod(0o600)
        return path

    pipe_command = f"exec cat >> {shlex.quote(str(path))}"
    if marker == str(path) and path.is_file():
        path.chmod(0o600)
        result = _tmux(
            "pipe-pane",
            "-o",
            "-t",
            session,
            pipe_command,
        )
    else:
        _create_private_log(path)
        buffer_name = f"dvr-console-seed-{os.getpid()}"
        result = _tmux_sequence(
            ("capture-pane", "-b", buffer_name, "-t", session, "-S", "-"),
            ("save-buffer", "-b", buffer_name, str(path)),
            ("delete-buffer", "-b", buffer_name),
            ("pipe-pane", "-o", "-t", session, pipe_command),
            ("set-option", "-t", session, LOG_OPTION, str(path)),
        )
    if result.returncode:
        raise ConsoleLogError(
            result.stdout.strip() or "could not enable the tmux console log"
        )
    path.chmod(0o600)
    return path


def main(argv: list[str]) -> int:
    if argv != ["ensure"]:
        print("usage: dvr_console_log.py ensure", file=sys.stderr)
        return 2
    try:
        print(ensure_console_log())
    except ConsoleLogError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
