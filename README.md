# Linux port for the DHB_AX board

This project is a port of mainline Linux to the LTS LTD2704XE-P DVR. This device is built on the HiSilicon Hi3531 SoC and uses a Shenzhen TVT Digital motherboard silkscreened **`DHB_AX V1.2`**. The same board ships under several other retail brands.

The Hi3531 has no upstream support. This port names the SoC `hisilicon,hi3531` and the board `tvt,dhb-ax`, following mainline convention. HiSilicon's name for their own Hi3531 reference board was `godnet`.

This repository contains the maintained Linux and Buildroot implementation, along with a [Debian root filesystem](debian/README.md) using the Buildroot kernel.

## Kernel patch development

The kernel changes are maintained as a Buildroot patch queue. Configure `DHB_AX_LINUX_REPOSITORY` in `local.env` to point to a shared bare clone of the stable kernel repository. Create that clone once, then run `kernel-patches prepare` to create the ignored Git editing workspace:

```sh
git clone --bare https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git ~/workspace/linux
./scripts/kernel-patches prepare
```

The workspace uses three reference points: the upstream release tag identifies the pinned Linux version, `dhb-ax-base` marks the pristine source before the port, and `dhb-ax-exported` marks the last `dhb-ax` commit successfully exported to the patch queue.

For fast iteration, modify files under `kernel/linux` and rebuild from the project root:

```sh
./scripts/buildroot.sh --config minimal linux-rebuild all
./tools/dvr-stage minimal-tftp
./tools/dvr-boot minimal-tftp
```

While `kernel/linux` has commits or local changes beyond `dhb-ax-exported`, the build wrapper automatically uses it through Buildroot's `LINUX_OVERRIDE_SRCDIR` support and reports that choice. Otherwise it reports and uses the canonical patch queue.

Once the change works, commit it on the `dhb-ax` branch and regenerate the canonical patch queue:

```sh
./scripts/kernel-patches export
./scripts/buildroot.sh --config minimal linux-dirclean
./scripts/buildroot.sh --config minimal
```

Export verifies the generated queue before moving `dhb-ax-exported`. Run `kernel-patches verify` at any later time to prove that applying the checked-in queue to `dhb-ax-base` still produces the exact `dhb-ax-exported` Git tree. The clean Buildroot build separately proves that the queue applies and compiles through the maintained build configuration.

The generated tree uses the exclusions in `scripts/kernel-sparse-checkout` to omit upstream paths whose names differ only by case, because those files cannot coexist on the default macOS filesystem.

## Hardware Guide

The [DHB_AX hardware guide](https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/README.md) was created as a technical reference for the SoC and board and should be useful to other porting efforts.

## Remaining Work

Remaining port work is tracked [here](doc/remaining-work.md) ranked by value and effort.
