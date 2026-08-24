# Minimal image as a storage bootstrap

## Goal

Use the built-in-initramfs image to prepare the fitted USB flash drive and SATA
HDD, then install the production Buildroot system without relying on an NFS
root.

The normal workflow will be:

```sh
tools/dvr-boot.sh tftp \
  artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal \
  --root initramfs
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-install-system.sh
```

An installed minimal image may also be loaded from USB:

```sh
tools/dvr-boot.sh usb uImage-minimal --root initramfs
```

The production `rootfs.tar` and uImage remain on the development host and are
staged into the RAM filesystem over SSH. A successful installation leaves the
minimal image running; booting the installed production system remains a
separate `tools/dvr-boot.sh usb` command.

## Agreed design

- Accept a bootstrap environment when its hostname is `minimal` and
  `/proc/mounts` reports `rootfs` mounted at `/`. This accepts the same
  minimal image loaded through either TFTP or USB and rejects the production
  HDD and NFS roots.
- Keep `dvr-prepare-storage.sh` and `dvr-install-system.sh` as separate
  commands. Preparation retains the explicit `--destroy-all-data` argument.
- Stage both production artifacts in RAM before installation. The current
  files total about 26 MB, well within the available memory.
- Add only the kernel drivers, filesystems and userspace tools needed by the
  existing provisioning scripts.
- Use the USB filesystem label and HDD root PARTUUID to identify installation
  targets. Preparation retains its topology, model, capacity and removability
  checks because the target partitions do not exist until it creates them.
- Keep SPI NOR, NAND and the saved U-Boot environment out of scope.
- Leave `--kernel-only` and `--minimal` behavior unchanged.

Booting the minimal image from USB and then repartitioning that USB is valid
because the kernel and root filesystem are already in RAM. If installation
fails after erasing the USB, recovery requires another TFTP boot.

## Minimal image changes

### Device tree and kernel

Enable the storage paths already used by the production image:

- the Hi3531 SATA/AHCI controller;
- the USB PHY and EHCI/OHCI host controllers;
- SCSI disk and USB mass storage;
- GPT and MBR partition parsing; and
- ext4 and VFAT.

Build these into the minimal kernel so provisioning does not depend on loading
modules. Leave unrelated peripherals such as GPIO, I2C, SPI, video and audio
disabled.

### Userland

Add the commands used to create and identify the target filesystems:

- `sfdisk`;
- `mke2fs`;
- `mkfs.fat`; and
- `blkid`.

BusyBox supplies the remaining shell, archive, mount and checksum commands.
Select the smallest practical Buildroot package set and omit surplus
maintenance tools where convenient. Retain Dropbear for DHCP-accessible,
public-key SSH.

The current Dropbear payload is 5,853,367 bytes. The U-Boot payload ceiling is
8,355,840 bytes, leaving about 2.5 MB for the storage additions. The existing
post-image size check remains the authority: if a clean build exceeds it,
reduce package scope before proceeding.

## Provisioning tool changes

### `dvr-prepare-storage.sh`

Replace the NFS-root requirement with:

```sh
[ "$(hostname)" = minimal ]
awk '$2 == "/" && $3 == "rootfs" { found = 1 }
     END { exit !found }' /proc/mounts
```

Keep the established preparation-device checks and partition layouts:

- one GPT ext4 partition on the WDC HDD with PARTUUID
  `ca264b64-5738-4e60-a0ab-b3c3a4c789c1`; and
- one bootable FAT32 partition on the Corsair USB drive.

Continue refusing mounted or active-swap targets.

### `dvr-install-system.sh`

Apply the same minimal/rootfs check to full installation instead of requiring
NFS. Keep the two USB-only modes as they are.

Stage `rootfs.tar` and the production uImage in `/tmp` with `scp`. The minimal
image's Dropbear configuration is assumed to support the SFTP transport used by
current `scp` clients. Then reuse the current installation flow:

1. Format and mount the HDD root partition.
2. Extract `rootfs.tar` and check that the installed system has `/sbin/init`.
3. Write the production kernel to a temporary file on the USB FAT filesystem.
4. Verify it and rename it to `/uImage`.
5. Unmount both targets and report success without rebooting.

## Repository updates

- Update the minimal DTS, kernel config and Buildroot defconfig.
- Add a minimal-specific post-build check for the required provisioning tools
  and absence of factory-flash writers.
- Update `README.md`, `AGENTS.md` and the maintained-status text in
  `plans/minimal-kernel.md`.
- Record the completed build and hardware results in this file.

## Implementation order

1. Add the minimal kernel, DT and userland storage support.
2. Clean-build the minimal image and confirm it fits under the U-Boot limit.
3. Update the preparation and installation scripts.
4. Boot minimal and confirm SSH plus both storage devices.
5. Exercise the environment checks from minimal and production roots.
6. Run the destructive preparation and full installation.
7. Boot the installed production system and verify its HDD root and SSH access.
8. Update the documentation with the observed sizes, hashes and results.

## Acceptance

- The clean minimal image fits under the vendor U-Boot payload limit.
- TFTP- and USB-loaded minimal images can see the fitted HDD and USB drive.
- Full preparation and installation run only when the hostname is `minimal`
  and the root filesystem is `rootfs`.
- Installation selects the USB by label and HDD by PARTUUID; preparation
  retains its device identity checks before either partition exists.
- The installed USB kernel and HDD root boot as the production system.
- No factory flash or saved U-Boot environment is modified.
- Installation leaves the minimal image running.

## Execution results

### Build validation (2026-08-23)

A clean `scripts/buildroot.sh --config minimal` build completed with the
storage bootstrap enabled. Its generated initramfs contains `sfdisk`,
`mke2fs`, `mkfs.fat`, and `blkid`; the audit found no `flash_erase`,
`flash_eraseall`, `flashcp`, `nandwrite`, or `ubiformat` binary.

The appended zImage and DTB payload is 6,882,719 bytes, leaving 1,473,121
bytes below the 8,355,840-byte vendor U-Boot ceiling. The wrapped
`uImage-hi3531-dhb-ax-minimal` is 6,882,783 bytes with SHA-256
`a8db1e57fd68d6a8b93708b48c407c302e231796f2718a439ffe08f6b05251a8`.

The generated kernel configuration has the SATA/AHCI path, USB PHY/EHCI/OHCI
and mass storage, SCSI disk, GPT/MBR parsing, ext4, FAT/VFAT, and the CP437
and ISO-8859-1 NLS tables all built in.

### Hardware validation (2026-08-23)

The corrected minimal image booted over TFTP after a hard reset cleared the
vendor U-Boot PHY state. It reached `minimal` with `rootfs` mounted at `/`,
obtained its DHCP lease and accepted public-key SSH. The built-in storage paths
identified the Corsair Flash Voyager USB drive as `/dev/sda` through
`100b0000.usb` and the WDC WD10EURX-63C HDD as `/dev/sdb` through
`10080000.sata`; both matched their required sector count and removability.

The first installation attempt exposed a missing FAT NLS table: mounting the
prepared USB reported `codepage cp437 not found`. Rebuilding with built-in
CP437 and ISO-8859-1 support produced a read-only VFAT mount with
`codepage=437,iocharset=iso8859-1`, after which destructive preparation and
full installation succeeded.

Preparation created the WDC GPT ext4 root partition with PARTUUID
`ca264b64-5738-4e60-a0ab-b3c3a4c789c1` and the Corsair FAT32 partition labeled
`DHBAXBOOT`. The installation staged both production artifacts in RAM,
extracted the root filesystem, and wrote `/uImage`. The installed production
system then booted from USB with its HDD root: Linux 6.18.42, hostname
`dhb-ax`, and `/dev/root` mounted as ext4. Its USB `/uImage` SHA-256 was
`956d5f9559b89ee020ab042ddd119fe876391c31c3fe58d6364733ea83cf3573`, matching
the development artifact and the USB checksum file. No SPI NOR, NAND, or saved
U-Boot environment write was issued.
