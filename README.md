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

Validated on the board: both Cortex-A9 cores, both 512 MiB DRAM banks, gigabit
Ethernet, SATA and ext4 root, EHCI/OHCI USB, all nineteen GPIO controllers, the
bit-banged I²C bus and battery-backed RTC, NFS, and OpenSSH. The proprietary
media pipeline is out of scope.

[Remaining hardware work](doc/remaining-work.md) lists what is not yet driven,
ranked by value and effort.

## Build

```sh
scripts/bootstrap-sources.sh
install -m 600 local.env.example local.env   # then fill in the required values
scripts/buildroot.sh
```

`local.env` holds machine-local configuration and is gitignored. The build
refuses to start without a root password hash in it, so the serial console
cannot be left open by accident; `local.env.example` documents the keys.

Maintained board support lives in `br2-external/`. `kernel/` and `buildroot/`
are regenerated source trees. Build outputs are written to
`artifacts/buildroot/`; the normal boot image is
`uImage-hi3531-dhb-ax`.
