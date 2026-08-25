# Debian armhf Dual-Userspace Enablement

## Summary

Enable the DVR to boot either Buildroot or Debian Trixie from separate HDD
partitions using the same production kernel. Build Debian entirely on the
development host with `mmdebstrap`, retain the minimal initramfs as the
recovery/provisioning environment, and never modify factory flash or saved
U-Boot state.

Update this document with artifact sizes, hashes, and hardware-validation
results as implementation proceeds.

## Implementation

### Kernel and build artifacts

- Expand the production kernel configuration for a conventional Debian
  systemd server: cgroups and namespaces except user namespaces; IPv6,
  inotify, fanotify, autofs, ACLs, security and trusted xattrs; tmpfs xattrs,
  nftables, seccomp, and normal systemd prerequisites.
- Leave container-focused features such as overlayfs, user namespaces,
  container virtual networking, and broad eBPF support disabled.
- Continue using the separate minimal kernel for recovery.
- Add GNU tar plus ACL/xattr support to minimal so installations preserve
  ownership, capabilities, ACLs, xattrs, hardlinks, and timestamps.
- Require the minimal appended kernel/DTB/initramfs payload to retain at least
  512 KiB of margin beneath the 8,355,840-byte U-Boot limit.
- Export the production modules as
  `artifacts/buildroot/kernel-modules.tar`, preserving
  `/lib/modules/<release>` metadata. Fail the production Buildroot export
  unless it contains exactly the configured kernel release.

### Debian root filesystem

- Add `scripts/mmdebstrap.sh` and a `just debian` entry, independent of the
  Buildroot `--config` interface.
- Run a pinned Debian Trixie armhf builder container as `linux/arm/v7`; use
  native armhf execution through Docker's existing emulation rather than a
  foreign-bootstrap second stage.
- Construct the filesystem with `mmdebstrap --variant=minbase`, current
  `trixie`, `trixie-updates`, and `trixie-security` repositories, and no
  recommended packages.
- Install `systemd-sysv`, `udev`, `dbus`, `systemd-resolved`,
  `systemd-timesyncd`, `openssh-server`, `ca-certificates`, `nftables`, `kmod`,
  `e2fsprogs`, `dosfstools`, `util-linux`, `smartmontools`, `iproute2`,
  `ethtool`, `procps`, `psmisc`, `lsof`, `curl`, `rsync`, `less`, and
  `vim-tiny`.
- Configure hostname `dvr`, `America/New_York`, `C.UTF-8`, and no sudo user.
- Use `DHB_AX_ROOT_PASSWD` from `local.env` for root console authentication.
  Permit root SSH only with public keys.
- Reuse the board's OpenSSH host keys and `authorized_keys` from
  `artifacts/local/ssh`. Buildroot independently consumes the Dropbear forms
  generated for the same board.
- Configure `systemd-networkd`: a `.link` applies the factory MAC and stable
  `eth0` name; a `.network` enables DHCP while preserving kernel-supplied
  NFS-root networking.
- Mount the data filesystem at `/srv/data` and enable the shared swap
  partition in Debian. Buildroot leaves both inactive by default.
- Add negative APT pins and documentation preventing installation of Debian
  kernel/header packages, `flash-kernel`, and U-Boot packages. Normal
  userspace APT upgrades remain supported.
- Embed the exact production module archive and generate
  `artifacts/debian/rootfs.tar`, `rootfs.tar.sha256`, `packages.txt`, and
  `build-info.txt`.
- Create the canonical rootfs artifact as an uncompressed GNU tar with numeric
  ownership, ACLs, all xattrs/capabilities, hardlinks, and timestamps
  preserved.

### Profiles, storage, and deployment

- Keep `/uImage` as the only production USB kernel, with `/uImage-minimal`
  retained for recovery.
- Rename `main-usb-hdd` to `buildroot-usb-hdd` and `main-tftp-nfs` to
  `buildroot-tftp-nfs`. Add `debian-usb-hdd` and `debian-tftp-nfs`; keep the
  Buildroot configuration name `main`.
- Remove obsolete duplicate `configs/dvr-boot` profiles; `tools/configs`
  remains the sole maintained profile directory.
- Extend HDD-profile rootfs configuration with a required filesystem label.
  Use it for staging validation while retaining PARTUUID boot arguments.
- Destructively rebuild the approved SATA HDD with these aligned GPT
  partitions:

| Partition | Start | End | Size | Label | PARTUUID |
|---|---:|---:|---:|---|---|
| Buildroot root | 2048 | 67110911 | 32 GiB | `dhb-ax-buildroot` | `ca264b64-5738-4e60-a0ab-b3c3a4c789c1` |
| Debian root | 67110912 | 201328639 | 64 GiB | `dhb-ax-debian` | `8EBB5255-A43A-4B4E-953D-E81D2E0A2A6F` |
| Swap | 201328640 | 209717247 | 4 GiB | `dhb-ax-swap` | `D8E11399-926E-4805-BC25-641EB3BE6C54` |
| Shared data | 209717248 | end of disk | remainder | `dhb-ax-data` | `FCB65DE3-F88D-4F21-BAB7-C85F5587C9E2` |

- Generalize `dvr-stage`: validate checksums and labels; permit complete HDD
  installation only from minimal; stream metadata-safe rootfs extraction;
  stage NFS roots through an incoming directory; and validate init, OS
  identity, and module release.
- Replace the Buildroot-only USB preflight with a device-tree board identity
  check so kernel-only staging works from either production userspace.
- Teach console identification and clean reboot handling about Debian.
- Update defaults, help, README, AGENTS guidance, `local.env.example`, and
  Justfile examples for the renamed and added profiles.

## Validation and rollout

- Run shell/Python syntax checks, load every profile, verify CLI help, and
  confirm the Justfile routes all four production profiles correctly. Do not
  restore mocked Python unit tests.
- Clean-build the shared toolchain, production Buildroot image, minimal image,
  and Debian rootfs.
- Verify minimal payload margin, tar metadata, module release, package
  manifest, checksums, and forbidden-package policy.
- Prove Debian first over NFS, then boot minimal, prepare storage, stage both
  roots and both USB kernels, and validate Buildroot, Debian, and the switch
  back to Buildroot.
- Record final artifact hashes, image sizes, package manifest location, and
  live results below.

## Assumptions

- The fitted HDD and approved USB drive may be erased during rollout.
- SPI NOR, NAND, factory backups, and saved U-Boot environment remain
  untouched.
- Buildroot and Debian share one production kernel and module set.
- Debian receives normal in-place APT userspace updates; recovery or clean
  reinstall uses the generated rootfs artifact.
- Root filesystems are fixed ext4 partitions; shared bulk data lives on
  `/srv/data`.
- There is no automatic boot-menu or persistent U-Boot environment change;
  profile-driven volatile boot commands select the userspace.

## Execution results

Implementation and rollout completed on 2026-08-25 UTC. The development host
clean-built the shared SDK, production Buildroot image, final minimal recovery
image, and Debian rootfs. The final minimal payload leaves 1,126,825 bytes
beneath the 8,355,840-byte U-Boot ceiling.

Final shell and Python syntax checks, whitespace checks, CLI help, all seven
profile loads, and Justfile dry-runs for all four production profiles passed.

### Final artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz` | 101,484,916 | `51a5029b587d50bcfa669bac9ac35a714f2bc74e84efbb369f01e8f6d01d1024` |
| `artifacts/buildroot/uImage-hi3531-dhb-ax` | 4,107,133 | `86cbe0ac5edac8111b85343d77b91f1127fcecaf606cbb9caa0aa85a55c4a5b2` |
| `artifacts/buildroot/rootfs.tar` | 10,680,320 | `97f87c5e57dc3f99a9db69b688a8832a1a9b9f99af698bb2f4d6a98522e2495f` |
| `artifacts/buildroot/kernel-modules.tar` | 624,640 | `9d75b38c62262384b8f5ee408f47bf91082b9f08b1b8f14d76317e62e1b6f3b9` |
| `artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal` | 7,229,079 | `7811f33b53e67155df682e1e150d9cad3302a4b6644441f65f5768fe8249eb57` |
| `artifacts/buildroot-minimal/rootfs.cpio` | 8,348,672 | `8e9c76f54bb373745d3136498de2352cea36dfb32717efa02c658eb6a98ca1c3` |
| `artifacts/debian/rootfs.tar` | 221,388,800 | `fa46d5839d73f526d7f4f5b7e3e6b7acdcfbf6caf463e575e6746172b6710462` |

The Debian build used pinned builder base
`debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258`,
`mmdebstrap 1.5.7`, and kernel release `6.18.42`. The 163-package manifest is
`artifacts/debian/packages.txt` (SHA-256
`ffce63c9568d8548c4d822191ad2c9eacf405f3ea83ed30c71a00345cb408e20`);
the build provenance is in `artifacts/debian/build-info.txt` (SHA-256
`a4492d9cefc65a158f2689d4f89cc3fb62ae861f9610015dc2e9aa20781c1de2`).
The rootfs checksum sidecar verifies successfully.

The PR-review follow-up rebuilt this Debian artifact after moving static
configuration into the tracked overlay, selecting hostname `dvr`, and changing
the timezone to `America/New_York`. It passed host-side archive validation but
was not restaged onto the DVR during review; the live rollout results below
describe the earlier artifact from the same implementation run.

### Artifact validation

- The production module archive contains exactly `lib/modules/6.18.42`, has
  numeric root ownership, and matches both production userspaces.
- Every requested Debian package is present. No Debian kernel, header,
  `flash-kernel`, or U-Boot package is installed. After a live `apt-get
  update`, representative packages from every forbidden class had pin
  priority `-1` and candidate `(none)`.
- GNU tar lists numeric ownership and preserves the rootfs hardlink
  `usr/bin/perl5.40.1` to `usr/bin/perl`. The generated Debian package set has
  no non-default ACL or file-capability entries of its own.
- A live round trip using the final minimal image preserved numeric owner
  `123:456`, mode, a named-user POSIX ACL, a user xattr, a
  `security.capability` xattr, hardlink inode identity, and the exact
  `2020-01-02 03:04:05 UTC` timestamp on ext4.
- ED25519, ECDSA, and RSA fingerprints in the running Debian OpenSSH server
  exactly matched the OpenSSH keys in `artifacts/local/ssh`.

### Storage and live rollout

- The approved 7.5 GiB USB drive and 931.5 GiB SATA HDD were erased. The HDD
  now has the exact planned partition starts, sizes, GPT labels, and PARTUUIDs;
  the USB filesystem label is `DHBAXBOOT`.
- A rollout postflight exposed case-sensitive comparison of textual GPT UUIDs.
  The disk layout was correct. Review removed the redundant post-write check;
  staging canonicalizes UUID hex case when locating a target partition.
- The first metadata-safe extraction exposed missing ext4 ACL support in the
  minimal kernel. Minimal now includes ext4/tmpfs ACL and xattr/security
  support; a clean rebuild and live metadata probe passed before both roots
  were installed cleanly.
- `buildroot-usb-hdd` booted from PARTUUID
  `ca264b64-5738-4e60-a0ab-b3c3a4c789c1`. SSH and production module loading
  worked; swap and `/srv/data` were inactive.
- `debian-usb-hdd` booted from PARTUUID
  `8ebb5255-a43a-4b4e-953d-e81d2e0a2a6f`. Systemd reported `running` with no
  failed units; DHCP, public-key SSH, `eth0`, factory MAC
  `00:18:ae:3c:a2:49`, production modules, nftables, NTP, swap, and
  `/srv/data` all passed.
- The DVR switched back to `buildroot-usb-hdd` successfully. It was left
  running Buildroot 6.18.42 from the expected PARTUUID with no swap or data
  mount active.
- At the user's direction, the Debian TFTP/NFS live proof was deferred to a
  later session. Both NFS profiles and their staging routes passed static
  profile validation, but this document does not claim a live NFS boot.
- No hard reset was required. SPI NOR, NAND, factory backups, and saved U-Boot
  environment were not modified.
