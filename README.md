# Linux port for the DHB_AX board

Running mainline Linux on a Shenzhen TVT Digital motherboard silkscreened
**`DHB_AX V1.2`**, built on the HiSilicon Hi3531 and sold as the LTS
LTD2704XE-P four-channel analog CVBS digital video recorder. TVT is the
original design manufacturer, and the same board ships under other retail
brands.

It shipped with Linux 3.0.8 and a stack of binary-only vendor modules. This
project replaces that with Linux 6.18.42 LTS. The kernel is loaded from USB
flash by hand at the U-Boot serial console; Linux then mounts its Buildroot
root filesystem from the internal SATA HDD, and TFTP/NFS remain available for
development and recovery. The port drives as much of the hardware as can be
supported without vendor blobs.

The Hi3531 has no upstream support: `hi3531` appears nowhere in the mainline
tree. What mainline does supply is drivers for the licensed IP the SoC is built
from — PL011, PL022, PL061, SP804, GIC, `stmmac` and `ahci_platform` — so the
patch queue is mostly per-SoC glue rather than new drivers. This port names the
SoC `hisilicon,hi3531` and the board `tvt,dhb-ax`, following mainline
convention, in place of the vendor's `godnet`, which is HiSilicon's name for
their own Hi3531 reference board rather than this one.

The [DHB_AX hardware guide](https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/README.md)
is the technical reference for the SoC and board. This repository contains the
maintained Linux and Buildroot implementation.
[Why the work lives in two repositories](doc/repository-split.md) covers the
division and where a given change belongs.

## Status

[Remaining hardware work](doc/remaining-work.md) lists what is not yet driven,
ranked by value and effort.

## Build

```sh
scripts/bootstrap-sources.sh
install -m 600 local.env.example local.env   # then fill in the required values
scripts/buildroot.sh --config toolchain
scripts/buildroot.sh --config main
scripts/buildroot.sh --config minimal
```

The first bootstrap on a checkout prepares the pinned sources, then exits with
the toolchain command above until the shared musl SDK has been staged. The SDK
is built only when the toolchain configuration changes; image builds unpack it
from the shared download volume instead of rebuilding gcc, binutils and musl.
`main` is the default configuration, so its command may also be written as
`scripts/buildroot.sh`. The minimal configuration is independent of the
production root filesystem: it builds a reduced kernel and BusyBox initramfs
that reach `minimal login:` on the UART, obtain the board's normal DHCP lease,
and serve the same public-key-only Dropbear and SFTP configuration as the main
image. It includes the SATA and USB storage paths plus the partitioning and
filesystem tools needed to bootstrap the normal USB-kernel/HDD-root system;
GPIO and I²C remain excluded. The image omits the outbound SSH client; SSH
access from the development host is the bootstrap interface.

Each configuration has its own output volume. Use `--config NAME --clean` to
drop one output tree while retaining downloads, the staged SDK and the shared
compiler cache.

`local.env` holds machine-local configuration and is gitignored. The build
refuses to start without a plaintext root password in it, then Buildroot
derives the crypt hash installed in the image. `dvr-boot` uses the same value
to request clean reboots through the serial console; `local.env.example`
documents the keys.

`artifacts/local/ssh/` is also machine-local. It holds `authorized_keys` and
the per-board Dropbear host keys.

Maintained board support lives in `br2-external/`. `kernel/` and `buildroot/`
are regenerated source trees. Production outputs are written to
`artifacts/buildroot/`; the normal boot image is `uImage-hi3531-dhb-ax`.
Diagnostic outputs are written to `artifacts/buildroot-minimal/`; its boot
image is `uImage-hi3531-dhb-ax-minimal` and its generated root filesystem is
`rootfs.cpio`.

## Staging and booting

Deployment and booting use named profiles under `tools/configs/`.
`dvr-stage` prepares the profile's kernel and external root filesystem;
`dvr-boot` only drives the serial console and boots artifacts that are already
in place. Machine access values come from `local.env`; profiles contain only
references to those values where their boot arguments require them.

```sh
tools/dvr-stage.sh main-tftp-nfs
tools/dvr-boot.sh main-tftp-nfs
```

The supplied profiles are `main-usb-hdd` (USB kernel and HDD root),
`main-tftp-nfs` (TFTP kernel and NFS root), `minimal-tftp` and `minimal-usb`
(embedded initramfs), and `uboot` (leave the board at the U-Boot prompt).
Use `dvr-boot --status` to identify the current console state and `--check` for
a non-mutating preflight. `dvr-stage --kernel-only` skips an external root
filesystem.

## Storage bootstrap

Boot the minimal image, then prepare and install the production system without
an NFS root:

```sh
tools/dvr-stage.sh minimal-tftp
tools/dvr-boot.sh minimal-tftp
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-stage.sh main-usb-hdd
```

The storage preparation and full production staging commands run only when the
DVR hostname is `minimal` and its `/` mount is `rootfs`. Preparation destroys
the approved HDD and USB contents; if it erases the USB before staging
finishes, recover by booting `minimal-tftp`. Full production staging reformats
the existing HDD root partition and updates the USB kernel. It leaves the
minimal image running; boot the installed system separately:

```sh
tools/dvr-boot.sh main-usb-hdd
```
