# Plan: a shared cross-toolchain

Build the cross-toolchain once, in a Buildroot configuration that exists only
to produce it, and have every image configuration consume it as an external
toolchain. Prerequisite for [minimal-kernel.md](minimal-kernel.md), which adds
a second image and so a second output tree.

## Why

Buildroot's internal toolchain is a per-output-tree artifact: it is built into
`$(O)/host`, so two output trees means two toolchains. For a target this small
gcc, binutils and the C library dominate a from-scratch build -- BusyBox, Dropbear and
the storage tools are quick by comparison -- so the duplication is most of the
cost of having a second configuration at all, and it recurs on every kernel
version bump, Buildroot upgrade and `--clean`.

The toolchain is genuinely identical between the configurations. What varies
between them is the package set, and that lives in each tree's own staging and
target directories, not in the compiler. An external toolchain contributes the
compiler and its libc; Buildroot builds each configuration's target libraries
on top, in that configuration's own staging. So the expensive,
configuration-independent half is shared and the configuration-dependent half
stays separate.

No suitable prebuilt exists for this host. The relevant prebuilt toolchains
are distributed as x86_64 host binaries and this container is aarch64 -- the
same constraint that made `BR2_TOOLCHAIN_EXTERNAL_BOOTLIN` vanish silently
from `.config` once, which is why `check_defconfig` exists. Nothing else
available through Buildroot pairs an aarch64 host with this 32-bit ARM target.
Hence building one rather than downloading one.

## The toolchain configuration

`br2-external/configs/dhb_ax_toolchain_defconfig` carries the target and
toolchain block from `dhb_ax_defconfig` verbatim and nothing else -- no
kernel, no packages, no root filesystem, no post-build or post-image script:

    BR2_arm=y
    BR2_cortex_a9=y
    BR2_ARM_ENABLE_VFP=y
    BR2_ARM_EABIHF=y
    BR2_ARM_FPU_VFPV3D16=y
    BR2_TOOLCHAIN_BUILDROOT=y
    BR2_TOOLCHAIN_BUILDROOT_MUSL=y

Musl 1.2.6 is the shared libc. Its smaller runtime gives the built-in minimal
initramfs more size margin, while the production package set remains supported.
`BR2_TIME_BITS_64` is glibc-only and is therefore absent; musl's 32-bit ABI
already uses 64-bit `time_t`.

Kernel headers stay at 6.18. `dhb_ax_defconfig` reaches that today through
`BR2_KERNEL_HEADERS_AS_KERNEL` plus
`BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18`; with no kernel in this
configuration the first of those has nothing to derive from, so the version is
named directly. The point of keeping 6.18 rather than choosing something else
is that the production image then compiles against exactly the headers it
compiles against now, which is the difference between a re-verification that
is expected to pass and one that is genuinely open.

Toolchain headers older than the kernel being built are normal and supported;
the combination that breaks is headers *newer* than the running kernel. See
the check below.

## Export

`make sdk` writes a relocatable tarball to the images directory, named from
`BR2_SDK_PREFIX` -- by default the target tuple, so
`arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz`. It depends on `world`,
which for this configuration is just the toolchain.

The build tooling stages that tarball into the shared `dhb-ax-br-dl` volume as
part of the `--config toolchain` run, because that is where the image
configurations read it from. Staging it automatically rather than leaving it
as a documented manual step is the difference between a missing SDK failing at
the moment it is produced and failing hours later in a different build.

`prepare-sdk` rewrites paths in the host directory in place to make it
relocatable. That is fine in a tree whose only purpose is producing the SDK.
Do not reach for the shortcut of running `make sdk` against an image
configuration's output volume to avoid building a toolchain: besides mutating
a tree the build depends on, the resulting sysroot carries that
configuration's package set, which is exactly the inheritance this
configuration exists to avoid.

## Consuming it

Both image configurations replace

    BR2_TOOLCHAIN_BUILDROOT=y
    BR2_TOOLCHAIN_BUILDROOT_MUSL=y
    BR2_KERNEL_HEADERS_AS_KERNEL=y

with an external custom toolchain downloaded from the staged tarball:

    BR2_TOOLCHAIN_EXTERNAL=y
    BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y
    BR2_TOOLCHAIN_EXTERNAL_DOWNLOAD=y
    BR2_TOOLCHAIN_EXTERNAL_URL="file:///dl/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz"

alongside the declarations Buildroot's external-toolchain menu asks for: the
tuple prefix, that the C library is musl, the kernel headers version, and the
capability flags for SSP, threads and C++. Take the exact symbol set from the
menu at implementation time rather than from this plan. Buildroot verifies
each declaration against the toolchain it unpacks and fails the build on a
mismatch, so a wrong declaration is loud -- which is the reason to prefer this
over any arrangement that merely puts a compiler on `PATH`.

`_DOWNLOAD` rather than `_PREINSTALLED`: each tree unpacks its own copy under
its host directory, which costs a few hundred megabytes against the ~10 GB
saved, and in exchange the output trees stay self-contained and
`scripts/buildroot.sh` needs no additional mount. The `dl` volume is already
shared by every configuration, so the tarball is already reachable from all of
them.

## Build tooling

This plan and `minimal-kernel.md` both need the `--config` selector; whichever
lands first introduces it. The name table gains a third row:

    --config      defconfig                    volume                      artifacts
    toolchain     dhb_ax_toolchain_defconfig   dhb-ax-br-toolchain-output  artifacts/toolchain
    (none) / main dhb_ax_defconfig             dhb-ax-br-output            artifacts/buildroot
    minimal       dhb_ax_minimal_defconfig     dhb-ax-br-minimal-output    artifacts/buildroot-minimal

- `--config toolchain` builds and exports in one run: `br sdk` rather than
  `br all`, followed by staging the tarball into `/dl`.
- Its output volume is deletable. Nothing consumes it once the SDK is staged,
  and it is rebuilt only when the toolchain itself changes, so `--clean
  --config toolchain` is a normal thing to do rather than a loss.
- `scripts/bootstrap-sources.sh` checks that the staged SDK exists and says
  what to run if it does not. It does not build it: bootstrapping currently
  fetches sources, and turning it into an hours-long compile would make a
  fresh checkout expensive for anyone who only wants to read the tree.
- `check_headers_not_newer`, beside `check_defconfig` in
  `buildroot-in-container.sh`: compare the headers version each image
  defconfig declares against its `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` and
  fail if the headers are the newer of the two. Older headers are fine and
  expected; this catches only the combination that does not work, and catches
  it before a build rather than as a runtime surprise.
- The SDK tarball must not reach `artifacts/buildroot/`. The copy loop at the
  end of `buildroot-in-container.sh` copies every regular file from
  `$output/images`, so with its own artifacts directory the toolchain build's
  tarball lands in `artifacts/toolchain/` and stays out of the image builds'
  output.

## Sequence

1. `--config` selector and the third name-table row, if `minimal-kernel.md`
   has not already introduced them.
2. `dhb_ax_toolchain_defconfig`, `--config toolchain`, and SDK staging into
   `/dl`. Confirm the tarball appears and contains a working cross compiler.
3. Switch `dhb_ax_defconfig` to the external toolchain and get the
   declarations right. Buildroot fails fast on a mismatch, so this iterates in
   seconds once the SDK exists.
4. `check_headers_not_newer`, and the `bootstrap-sources.sh` check.
5. Rebuild the production image and verify it on hardware.
6. Documentation: `README.md` and the `AGENTS.md` build section, including
   that a fresh checkout needs `--config toolchain` before anything else.

## Acceptance

- `scripts/buildroot.sh --config toolchain` produces an SDK tarball in
  `artifacts/toolchain/` and stages it into the `dhb-ax-br-dl` volume.
- A `--config main --clean` followed by a full rebuild produces a working
  production image without compiling gcc, binutils or musl.
- That image boots to the HDD root on the rig and behaves as the current one
  does. This is the criterion the whole plan turns on: the production image is
  being rebuilt against a differently-provenanced toolchain, and nothing else
  here is worth having if that regresses.
- Deliberately wrong declarations fail the build with Buildroot's own
  mismatch message rather than producing an image -- confirm once, by
  temporarily declaring glibc, that the check is real.
- `check_headers_not_newer` passes at 6.18 headers against a 6.18 kernel, and
  fails if the kernel version is lowered below the declared headers.
- `scripts/bootstrap-sources.sh` on a checkout with no staged SDK reports what
  to run and exits non-zero, rather than leaving the failure to a later build.

## Completion record (2026-08-23)

- The implementation uses Buildroot 2026.02.3 to produce GCC 14.3.0 with
  musl 1.2.6 for `arm-buildroot-linux-musleabihf`. A relocated SDK compiled a
  Cortex-A9/VFPv3-D16 hard-float test binary whose interpreter is
  `/lib/ld-musl-armhf.so.1`; `sizeof(time_t)` is 8 without a glibc-specific
  time-bits option.
- The exported SDK was 97 MiB. The artifact verified during implementation had
  SHA-256
  `dfce58240973a2d61f0309e06ee50e6b12a354cc1dddba7cf4e44af7150b7c17`;
  future rebuilds are expected to have a different hash when pinned inputs or
  build metadata change.
- A clean main build consumed the staged SDK and contained no gcc, binutils or
  musl source build. The production artifact directory contained the image
  outputs and no SDK tarball.
- Negative-path tests were exercised, not only inspected: declaring glibc
  produced Buildroot's `Incorrect selection of the C library` failure, a 6.17
  kernel declaration failed the 6.18-header guard, and a missing staged SDK
  made bootstrap exit with the documented recovery command.
- The production image booted with an NFS root before storage installation.
  It was then installed to the guarded Corsair USB boot device and the existing
  ext4 partition on the WDC WD10EURX HDD. The installed kernel's SHA-256
  matched the build artifact, and the deployed system booted kernel 6.18.42
  with `/dev/sda1` mounted read/write as `/`.
- Hardware verification after the HDD-root boot covered gigabit Ethernet,
  public-key SSH, both storage devices, `/dev/i2c-0`, the DS1307 RTC and system
  clock agreement. VFAT is a module in this kernel, so ad-hoc mounts of the USB
  boot partition require `modprobe vfat`; `tools/dvr-install-system.sh` already
  performs that step.
- `--config minimal` is wired to its own output and artifact locations but
  deliberately fails with a clear missing-defconfig error until
  `dhb_ax_minimal_defconfig` is implemented by `minimal-kernel.md`.
