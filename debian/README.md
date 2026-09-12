# Debian root filesystem

This directory contains the complete Debian Trixie armhf root filesystem definition for the DHB_AX board. Debian supplies userspace only. It boots the kernel built by Buildroot and contains that kernel's modules.

## Build

Build the Buildroot image first so that `artifacts/buildroot/kernel-modules.tar` exists, then build the Debian root filesystem:

```sh
./scripts/buildroot.sh
./debian/build
```

The builder also requires `DHB_AX_DVR_ETHADDR` in `local.env`, plus the authorized key and SSH host keys under `artifacts/local/ssh/`. Root has a locked password, logs in automatically on the serial console, and accepts only public-key authentication over SSH.

`build` creates an ARMv7 builder container from `Dockerfile`. The container runs `build-in-container.sh`, installs the packages in `packages.txt`, applies `overlay/`, adds the kernel modules and SSH material, and writes the results beneath `artifacts/debian/`.

The generated files are:

- `rootfs.cpio.gz`: root filesystem archive for HDD installation.
- `packages.txt`: installed package versions.
- `build-info.txt`: suite, architecture, builder and kernel metadata.

## Boot and installation

The `debian-usb-hdd` profile loads the kernel from USB and mounts the Debian root filesystem from its dedicated HDD partition.

Boot `buildroot-usb` or `buildroot-tftp` first so the HDD root is unmounted, then stage and boot Debian:

```sh
./tools/dvr-stage debian-usb-hdd
./tools/dvr-boot debian-usb-hdd
```

Storage initialization remains in `tools/dvr-prepare-storage` because it defines the complete HDD and USB layout shared by all operating systems.
