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

The builder prepares all artifacts in a temporary directory, then clears `artifacts/debian/` and copies in the completed set after a successful build.

The generated files are:

- `rootfs.cpio.xz`: root filesystem archive for HDD installation.
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

## Docker kernel support

The maintained kernel configuration includes support for rootful Docker with cgroup v2, OverlayFS, bridge/veth networking and published ports through Docker's iptables backend using `iptables-nft`. OverlayFS, bridge networking and the required xtables compatibility extensions are modules; NAT and the resource controllers are built in. Legacy iptables and legacy cgroup controllers remain disabled. CPU quotas are supported, but CPU-set pinning, rootless containers and Swarm are outside this configuration's target.

Docker is not installed by the current package list. When provisioning it, ensure `iptables` and `ip6tables` use their nft variants; this is distinct from Docker's native nftables backend. Use the matching kernel module archive and persistent ext4 storage for container data. Verify module loading, container DNS/outbound traffic, published ports, and CPU/memory limits on the DVR after rebuilding and booting. The configuration has passed Kconfig checks, but Docker runtime operation has not yet been tested on this board.
