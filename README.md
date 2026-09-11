# Linux port for the DHB_AX board

This project is a port of mainline Linux to the LTS LTD2704XE-P DVR. This device is built on the HiSilicon Hi3531 SoC and uses a Shenzhen TVT Digital motherboard silkscreened **`DHB_AX V1.2`**. The same board ships under several other retail brands.

The Hi3531 has no upstream support. This port names the SoC `hisilicon,hi3531` and the board `tvt,dhb-ax`, following mainline convention. HiSilicon's name for their own Hi3531 reference board was `godnet`.

This repository contains the maintained Linux and Buildroot implementation, along with a [Debian root filesystem](debian/README.md) using the Buildroot kernel.

## Kernel development

Buildroot always builds the kernel from the ignored `kernel/linux` Git workspace. The checked-in patch queue is the durable representation of the port and initializes a new workspace. Configure `DHB_AX_LINUX_REPOSITORY` in `local.env` to point to a shared bare clone of the stable kernel repository. Create that clone once, then prepare the workspace:

```sh
git clone --bare https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ~/workspace/linux
./scripts/kernel-sources prepare
```

The upstream release tag identifies the pinned Linux version, `dhb-ax-base` marks that pristine commit, and the `dhb-ax` branch contains the port commits imported from the patch queue.

Modify files under `kernel/linux` and rebuild from the project root:

```sh
./scripts/buildroot.sh --config minimal linux-rebuild all
./tools/dvr-stage minimal-tftp
./tools/dvr-boot minimal-tftp
```

Once the change works, commit it on the `dhb-ax` branch and export the commits back to the checked-in patch queue:

```sh
./scripts/kernel-sources export-patches
./scripts/buildroot.sh --config minimal linux-dirclean
./scripts/buildroot.sh --config minimal
```

`export-patches` uses `git format-patch` for every commit after `dhb-ax-base`. The clean Buildroot build then proves that the current kernel workspace compiles through the maintained configuration. Include the regenerated patches in the corresponding outer-repository commit; `kernel/linux` remains ignored and disposable.

The generated tree uses the exclusions in `scripts/kernel-sparse-checkout` to omit upstream paths whose names differ only by case, because those files cannot coexist on the default macOS filesystem.

## Hardware Guide

The [DHB_AX hardware guide](https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/README.md) was created as a technical reference for the SoC and board and should be useful to other porting efforts.

## Remaining Work

Remaining port work is tracked [here](doc/remaining-work.md) ranked by value and effort.
