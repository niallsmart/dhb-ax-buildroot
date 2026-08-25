"""Load and validate named DVR boot profiles."""

from __future__ import annotations

import ipaddress
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import tomllib

PROFILE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
REFERENCE = re.compile(r"\$\{([^{}]+)\}")
ETHERNET_ADDRESS = re.compile(r"(?i)([0-9a-f]{2}:){5}[0-9a-f]{2}")
LOAD_ADDRESS = re.compile(r"0x[0-9A-Fa-f]+")
USB_DEVICE = re.compile(r"[0-9]+:[0-9]+")
TARGET_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
FILESYSTEM_LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,15}")
OS_ID = re.compile(r"[a-z0-9][a-z0-9._-]*")
KERNEL_RELEASE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*")
PARTUUID = re.compile(
    r"PARTUUID=([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
)


class ProfileError(ValueError):
    """A boot profile is missing or invalid."""


@dataclass(frozen=True)
class LocalSettings:
    pi_ipaddr: str
    dvr_ipaddr: str
    dvr_netmask: str
    dvr_ethaddr: str
    root_password: str


@dataclass(frozen=True)
class Kernel:
    source: str
    artifact: Path
    target: str
    load_address: str
    usb_device: str | None = None


@dataclass(frozen=True)
class Rootfs:
    source: str
    artifact: Path | None = None
    device: str | None = None
    export: str | None = None
    label: str | None = None
    expected_os_id: str | None = None
    kernel_release: str | None = None

    @property
    def partuuid(self) -> str | None:
        if self.device is None:
            return None
        match = PARTUUID.fullmatch(self.device)
        return match.group(1) if match else None


@dataclass(frozen=True)
class Boot:
    action: str
    args: tuple[str, ...] = ()
    hostname: str | None = None
    timeout: int = 120

    @property
    def bootargs(self) -> str:
        return " ".join(self.args)


@dataclass(frozen=True)
class Profile:
    name: str
    boot: Boot
    kernel: Kernel | None = None
    rootfs: Rootfs | None = None


def repository_root() -> Path:
    return Path(
        os.environ.get("DVR_BOOT_REPO_ROOT", Path(__file__).resolve().parents[1])
    )


def _table(data: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    value = data.get(name)
    if not isinstance(value, dict):
        raise ProfileError(f"missing [{name}] table")
    return value


def _keys(table: Mapping[str, Any], name: str, allowed: set[str]) -> None:
    unknown = sorted(set(table) - allowed)
    if unknown:
        raise ProfileError(f"unknown {name} field: {unknown[0]}")


def _string(table: Mapping[str, Any], table_name: str, name: str) -> str:
    value = table.get(name)
    if not isinstance(value, str) or not value:
        raise ProfileError(f"{table_name}.{name} must be a non-empty string")
    return value


def _artifact(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def _lookup(data: Mapping[str, Any], reference: str) -> Any:
    value: Any = data
    for part in reference.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ProfileError(f"unknown profile reference: {reference}")
        value = value[part]
    return value


def _interpolate(
    value: Any,
    data: Mapping[str, Any],
    environ: Mapping[str, str],
    resolving: tuple[str, ...] = (),
) -> Any:
    if isinstance(value, list):
        return [_interpolate(item, data, environ, resolving) for item in value]
    if isinstance(value, dict):
        return {
            key: _interpolate(item, data, environ, resolving + (key,))
            for key, item in value.items()
        }
    if not isinstance(value, str):
        return value

    def replace(match: re.Match[str]) -> str:
        reference = match.group(1)
        if reference.startswith("env."):
            variable = reference.removeprefix("env.")
            if not variable.startswith("DHB_AX_"):
                raise ProfileError(f"unsupported environment reference: {reference}")
            replacement = environ.get(variable)
            if not replacement:
                raise ProfileError(f"environment variable is not set: {variable}")
            return replacement

        if reference in resolving:
            raise ProfileError(f"cyclic profile reference: {reference}")
        replacement = _interpolate(
            _lookup(data, reference), data, environ, resolving + (reference,)
        )
        if not isinstance(replacement, (str, int, float, bool)):
            raise ProfileError(f"profile reference is not a scalar: {reference}")
        return str(replacement)

    previous = None
    while previous != value:
        previous = value
        value = REFERENCE.sub(replace, value)
    return value


def load_local_settings(
    environ: Mapping[str, str] | None = None,
) -> LocalSettings:
    environ = os.environ if environ is None else environ
    values = {}
    for field, variable in (
        ("pi_ipaddr", "DHB_AX_PI_IPADDR"),
        ("dvr_ipaddr", "DHB_AX_DVR_IPADDR"),
        ("dvr_netmask", "DHB_AX_DVR_NETMASK"),
    ):
        value = environ.get(variable)
        if not value:
            raise ProfileError(f"environment variable is not set: {variable}")
        try:
            ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError as error:
            raise ProfileError(f"{variable} is not an IPv4 address") from error
        values[field] = value

    dvr_ethaddr = environ.get("DHB_AX_DVR_ETHADDR")
    if not dvr_ethaddr:
        raise ProfileError("environment variable is not set: DHB_AX_DVR_ETHADDR")
    if not ETHERNET_ADDRESS.fullmatch(dvr_ethaddr):
        raise ProfileError("DHB_AX_DVR_ETHADDR is not an Ethernet address")

    root_password = environ.get("DHB_AX_ROOT_PASSWD")
    if not root_password:
        raise ProfileError("environment variable is not set: DHB_AX_ROOT_PASSWD")
    if "\r" in root_password or "\n" in root_password:
        raise ProfileError("DHB_AX_ROOT_PASSWD cannot contain a newline")
    return LocalSettings(
        **values, dvr_ethaddr=dvr_ethaddr, root_password=root_password
    )


def _kernel(data: Mapping[str, Any], repo_root: Path) -> Kernel:
    table = _table(data, "kernel")
    _keys(
        table,
        "kernel",
        {"source", "artifact", "target", "load_address", "usb_device"},
    )
    source = _string(table, "kernel", "source")
    if source not in ("usb", "tftp"):
        raise ProfileError("kernel.source must be 'usb' or 'tftp'")
    target = _string(table, "kernel", "target")
    if not TARGET_NAME.fullmatch(target):
        raise ProfileError("kernel.target must be a safe filename")
    load_address = _string(table, "kernel", "load_address")
    if not LOAD_ADDRESS.fullmatch(load_address):
        raise ProfileError("kernel.load_address must be hexadecimal")
    usb_device = table.get("usb_device")
    if source == "usb":
        if not isinstance(usb_device, str) or not USB_DEVICE.fullmatch(usb_device):
            raise ProfileError("USB kernels require kernel.usb_device in N:P form")
    elif usb_device is not None:
        raise ProfileError("kernel.usb_device is only valid for USB kernels")
    return Kernel(
        source=source,
        artifact=_artifact(repo_root, _string(table, "kernel", "artifact")),
        target=target,
        load_address=load_address,
        usb_device=usb_device,
    )


def _production_kernel_release(repo_root: Path) -> str:
    defconfig = repo_root / "br2-external" / "configs" / "dhb_ax_defconfig"
    try:
        lines = defconfig.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ProfileError(f"cannot read production defconfig: {defconfig}") from error
    prefix = 'BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="'
    values = [
        line.removeprefix(prefix).removesuffix('"')
        for line in lines
        if line.startswith(prefix) and line.endswith('"')
    ]
    if len(values) != 1 or not KERNEL_RELEASE.fullmatch(values[0]):
        raise ProfileError("production defconfig must select one safe kernel release")
    return values[0]


def _rootfs(data: Mapping[str, Any], repo_root: Path) -> Rootfs:
    table = _table(data, "rootfs")
    _keys(
        table,
        "rootfs",
        {
            "source",
            "artifact",
            "device",
            "export",
            "label",
            "expected_os_id",
        },
    )
    source = _string(table, "rootfs", "source")
    if source not in ("hdd", "nfs", "initramfs"):
        raise ProfileError("rootfs.source must be 'hdd', 'nfs', or 'initramfs'")

    artifact = table.get("artifact")
    device = table.get("device")
    export = table.get("export")
    label = table.get("label")
    expected_os_id = table.get("expected_os_id")
    kernel_release = None
    if source in ("hdd", "nfs"):
        if not isinstance(expected_os_id, str) or not OS_ID.fullmatch(
            expected_os_id
        ):
            raise ProfileError(
                "external roots require a safe rootfs.expected_os_id"
            )
        kernel_release = _production_kernel_release(repo_root)
    if source == "hdd":
        if not isinstance(artifact, str) or not artifact:
            raise ProfileError("HDD roots require rootfs.artifact")
        if not isinstance(device, str) or not PARTUUID.fullmatch(device):
            raise ProfileError("HDD roots require rootfs.device as PARTUUID=<UUID>")
        if export is not None:
            raise ProfileError("rootfs.export is only valid for NFS roots")
        if not isinstance(label, str) or not FILESYSTEM_LABEL.fullmatch(label):
            raise ProfileError(
                "HDD roots require rootfs.label as a safe filesystem label"
            )
    elif source == "nfs":
        if not isinstance(artifact, str) or not artifact:
            raise ProfileError("NFS roots require rootfs.artifact")
        if (
            not isinstance(export, str)
            or not export.startswith("/srv/")
            or "/../" in export
            or "/./" in export
            or "//" in export
            or export.endswith(("/..", "/.", "/"))
            or not re.fullmatch(r"[A-Za-z0-9_./-]+", export)
        ):
            raise ProfileError("rootfs.export must be a canonical path beneath /srv")
        if device is not None:
            raise ProfileError("rootfs.device is only valid for HDD roots")
        if label is not None:
            raise ProfileError("rootfs.label is only valid for HDD roots")
    elif any(
        value is not None
        for value in (artifact, device, export, label, expected_os_id)
    ):
        raise ProfileError("initramfs roots have no external fields")

    return Rootfs(
        source=source,
        artifact=_artifact(repo_root, artifact) if artifact else None,
        device=device,
        export=export,
        label=label,
        expected_os_id=expected_os_id,
        kernel_release=kernel_release,
    )


def _boot(data: Mapping[str, Any]) -> Boot:
    table = _table(data, "boot")
    _keys(table, "boot", {"action", "args", "hostname", "timeout"})
    action = _string(table, "boot", "action")
    if action not in ("kernel", "prompt"):
        raise ProfileError("boot.action must be 'kernel' or 'prompt'")
    if action == "prompt":
        if set(table) != {"action"}:
            raise ProfileError("prompt profiles may only set boot.action")
        return Boot(action=action)

    args = table.get("args")
    if (
        not isinstance(args, list)
        or not args
        or not all(isinstance(item, str) and item for item in args)
    ):
        raise ProfileError("kernel profiles require a non-empty boot.args array")
    hostname = _string(table, "boot", "hostname")
    timeout = table.get("timeout", 120)
    if not isinstance(timeout, int) or isinstance(timeout, bool) or timeout < 1:
        raise ProfileError("boot.timeout must be a positive integer")
    return Boot(
        action=action, args=tuple(args), hostname=hostname, timeout=timeout
    )


def load_profile(
    name: str,
    *,
    repo_root: Path | None = None,
    environ: Mapping[str, str] | None = None,
    local_settings: LocalSettings | None = None,
) -> Profile:
    if not PROFILE_NAME.fullmatch(name):
        raise ProfileError("profile name must contain only letters, digits, '_' or '-'")
    repo_root = repo_root or repository_root()
    path = repo_root / "tools" / "configs" / f"{name}.toml"
    try:
        with path.open("rb") as stream:
            raw = tomllib.load(stream)
    except FileNotFoundError as error:
        raise ProfileError(f"unknown boot profile: {name}") from error
    except tomllib.TOMLDecodeError as error:
        raise ProfileError(f"invalid TOML in {path}: {error}") from error

    if not isinstance(raw, dict):
        raise ProfileError(f"invalid boot profile: {name}")
    _keys(raw, "profile", {"kernel", "rootfs", "boot"})
    environ = os.environ if environ is None else environ
    local_settings = local_settings or load_local_settings(environ)
    references = dict(raw)
    references["local"] = {
        "pi_ipaddr": local_settings.pi_ipaddr,
        "dvr_ipaddr": local_settings.dvr_ipaddr,
        "dvr_netmask": local_settings.dvr_netmask,
        "dvr_ethaddr": local_settings.dvr_ethaddr,
    }
    data = _interpolate(raw, references, environ)
    boot = _boot(data)
    if boot.action == "prompt":
        if "kernel" in data or "rootfs" in data:
            raise ProfileError("prompt profiles cannot define kernel or rootfs tables")
        return Profile(name=name, boot=boot)

    kernel = _kernel(data, repo_root)
    rootfs = _rootfs(data, repo_root)
    return Profile(
        name=name,
        boot=boot,
        kernel=kernel,
        rootfs=rootfs,
    )
