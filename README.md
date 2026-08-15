# Linux port for the LTS LTD2704XE-P DVR

Running mainline Linux on a four-channel analog CVBS digital video recorder,
sold as the LTS LTD2704XE-P.

The board is a Shenzhen TVT Digital motherboard silkscreened
**`DHB_AX V1.2`**, built on the HiSilicon Hi3531. TVT is the original design
manufacturer, and the same board ships under other retail brands. The vendor
U-Boot and 3.0.8 kernel call the platform `godnet`, which is HiSilicon's name
for their own Hi3531 reference board; mainline identifies it as
`hisilicon,hi3531`. It shipped
with Linux 3.0.8 and a stack of binary-only vendor modules. This project
replaces that with Linux 6.18.42 LTS. U-Boot loads the kernel from USB flash,
Linux mounts its Buildroot root filesystem from the internal SATA HDD, and
TFTP/NFS remain available for development and recovery. The port drives as
much of the hardware as can be supported without vendor blobs.

The sibling `../dhb-ax-guide/doc/README.md` is the technical reference for the
SoC and board. This repository contains the maintained Linux and Buildroot
implementation.

## Status

Validated on the board: both Cortex-A9 cores, both 512 MiB DRAM banks, gigabit
Ethernet, SATA and ext4 root, EHCI/OHCI USB, all nineteen GPIO controllers, the
bit-banged I²C bus and battery-backed RTC, NFS, and OpenSSH. The proprietary
media pipeline is out of scope.

## Build

```sh
scripts/bootstrap-sources.sh
scripts/buildroot.sh
```

Maintained board support lives in `br2-external/`. `kernel/` and `buildroot/`
are regenerated source trees. Build outputs are written to
`artifacts/buildroot/`; the normal boot image is
`uImage-hi3531-dhb-ax`.
