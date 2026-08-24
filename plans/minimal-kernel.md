# Plan: minimal kernel with a built-in initramfs

A second Buildroot target, `dhb_ax_minimal_defconfig`, producing a
self-contained uImage that reaches a root shell over the serial console or
Dropbear with no dependency on the HDD, a Raspberry Pi NFS export, or any
external root filesystem. It is a storage-bootstrap image: something to boot
when the normal kernel or root filesystem will not, to check the boot chain and
prepare the approved USB and HDD before installing the production system.
Ethernet is enabled for DHCP and SSH; SATA and USB are enabled only for that
bootstrap path, while GPIO and I²C remain outside its scope.

The image still has to be *loaded* from somewhere -- the USB FAT partition or
TFTP from the Pi. What it does not need is a root filesystem: the kernel
mounts the initramfs it carries and never processes `root=`.

The first implementation deliberately omitted networking. The networked
diagnostic extension recorded in the execution results supersedes the
UART-only package, DT and driver choices retained below as the original design
record.

This reuses the existing `br2-external` tree rather than a second Buildroot
checkout: same patch queue, same kernel source, same board directory. See the
prior discussion in this session for why a separate Buildroot was rejected in
favour of a second defconfig.

[shared-toolchain.md](shared-toolchain.md) is a prerequisite. Adding a second
image means a second Buildroot output tree, and Buildroot's internal toolchain
is a per-output-tree artifact -- so without it this plan would build gcc,
binutils and musl a second time and keep them on disk twice. That plan moves
both configurations onto one externally supplied toolchain; everything below
assumes it has landed, and the `--config` selector described in Build tooling
is shared between the two plans, introduced by whichever lands first.

## Existing state this builds on

Two pieces of this already exist, from board bring-up before drivers were
written:

- [`board/dhb-ax/dts/hisilicon/hi3531-dhb-ax-minimal.dts`](../br2-external/board/dhb-ax/dts/hisilicon/hi3531-dhb-ax-minimal.dts)
  enables only the CPU, GIC, SP804 timer, and PL011 UART0. GPIO, USB, SATA,
  Ethernet, SPI-NOR, and I²C all stay disabled as `hi3531.dtsi` leaves them.
- [`board/dhb-ax/post-image.sh`](../br2-external/board/dhb-ax/post-image.sh)
  already loops over two DTB stems, `hi3531-dhb-ax` and
  `hi3531-dhb-ax-minimal`, appending each to the *same* zImage from
  `dhb_ax_defconfig` and producing `uImage-hi3531-dhb-ax-minimal` on every
  build today.

That existing minimal uImage is not bootable to a shell: it pairs the minimal
DTB with the full kernel config and no rootfs at all, so `root=` still points
wherever the bootargs say, and the minimal DTB cannot reach any of them. This
plan gives it a rootfs and separates it from the main build so that pairing
stops being produced as a side effect of unrelated changes to
`dhb_ax_defconfig`.

## Size budget

The driver trim is a requirement, not tidiness. The production kernel
configuration plus a built-in initramfs does not fit the memory available to
the image at boot, which is what forces a second kernel config rather than
reusing `linux.config` with the minimal DTB.

Two limits bound the result, and both need measuring rather than assuming:

- The load window. `tools/dvr-boot.exp` loads the uImage at `0x82000000`,
  while `post-image.sh` declares mkimage load and entry addresses of
  `0x80008000`. Vendor U-Boot refuses a payload whose destination range reaches
  `0x80800000` with `kernel image will overwrite uboot`, so the appended zImage
  and DTB must be smaller than `0x7f8000` (8,355,840) bytes. The minimal
  post-image script enforces this before wrapping the payload.
- The USB FAT partition, which has to hold this image alongside the production
  `/uImage` (see "Installing on USB" below).

Record the measured `uImage-hi3531-dhb-ax-minimal` size and the boot-time
`Freeing initrd memory` / `Memory: ... available` lines the first time it
boots, and treat a later growth past that as a change to justify, not absorb.
A silently oversized image does not fail cleanly -- it corrupts itself during
relocation or decompression and hangs somewhere unhelpful.

## Kernel

- New defconfig `br2-external/configs/dhb_ax_minimal_defconfig`, sharing
  `BR2_GLOBAL_PATCH_DIR`, the kernel version, `BR2_LINUX_KERNEL_ZIMAGE`,
  `BR2_LINUX_KERNEL_DTS_SUPPORT`, `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR` and
  `BR2_PACKAGE_HOST_UBOOT_TOOLS` with `dhb_ax_defconfig`. A divergence in that
  kernel-image block breaks the appended DTB, so the overlap is not optional.
- The target and toolchain block -- `BR2_arm`, `BR2_cortex_a9`, the VFP and
  EABI settings and the external-toolchain declarations
  -- is also identical to `dhb_ax_defconfig`, and for a stronger reason: both
  configurations consume the same SDK, and Buildroot verifies each declaration
  against the toolchain it unpacks. A divergence here does not produce a
  differently-built userspace, it fails the build. See
  [shared-toolchain.md](shared-toolchain.md).
- Kernel config is a second, wholly separate full `.config`,
  `board/dhb-ax/linux-minimal.config`, derived from `linux.config` by turning
  drivers off in `menuconfig` and saving the result whole -- not written from
  scratch, and not merged from a fragment.
  - Derived from `linux.config` rather than from an ARM defconfig because a
    set of symbols has to survive that nothing in a stock configuration would
    supply, and each of them fails silently rather than loudly:
    - `CONFIG_ARM_APPENDED_DTB`, `CONFIG_ARM_ATAG_DTB_COMPAT` and
      `CONFIG_ARM_ATAG_DTB_COMPAT_CMDLINE_FROM_BOOTLOADER`
      (`linux.config:444-446`). `CONFIG_ATAGS` is off, so the vendor U-Boot's
      ATAGs are useful only through the compat path: without these the
      appended DTB is not found at all, and without the CMDLINE half the
      U-Boot `bootargs` are discarded -- no `console=`, no `mem=`, a dead
      UART and nothing on screen to say why.
    - The platform support the patch queue adds: the hi3531 SMP operations
      (patch 0010), the UART clock mux (patch 0002), and the system
      controller behind both.
    - `CONFIG_SERIAL_AMBA_PL011` with its console option, and the SP804
      timer. These are what the minimal DTB describes; losing either leaves
      an image with no console or no timekeeping.
    - `CONFIG_BLK_DEV_INITRD`, already on in `linux.config`, carried forward
      unchanged.
  - A fragment that lists driver symbols as "not set" was considered and
    rejected: Kconfig's dependency graph does not guarantee a symbol listed
    as not set actually stays off if something else still `select`s it, and
    this project has already hit that exact silent-failure shape once, which
    is why `check_defconfig` exists in `buildroot-in-container.sh`. A
    disabled-but-not-really symbol in a fragment fails quietly -- the image
    still boots, just larger than the size budget allows -- so nothing would
    surface the mistake. A full, explicit `.config` has no merge step to get
    wrong; `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG` +
    `BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE` treats it as authoritative and runs
    `olddefconfig` only to fill in anything genuinely absent, the same
    mechanism `linux.config` already relies on today.
  - The cost is duplication: most of `linux.config`'s ~2,600 lines are
    generic ARM/musl/filesystem options neither variant differs on, and
    `linux-minimal.config` carries its own copy of all of them. Nothing keeps
    the two files in sync automatically, so a kernel version bump or a
    patch-queue change that touches shared config needs applying to both by
    hand.
  - Regenerate `linux-minimal.config` from the built tree after any such
    change rather than hand-editing the diff -- but take it from the *first*
    kernel build's `.config`, before `linux-rebuild-with-initramfs` runs, or
    scrub the fixups afterwards. Buildroot's `LINUX_KCONFIG_FIXUP_CMDS`
    writes `CONFIG_INITRAMFS_SOURCE="${BR_BINARIES_DIR}/rootfs.cpio"`,
    `CONFIG_INITRAMFS_ROOT_UID=0` and `CONFIG_INITRAMFS_ROOT_GID=0` into the
    output tree's `.config`, alongside the compression options and any forced
    `CONFIG_MODULES`. Committing those makes the source file depend on the
    container's paths and encodes a value Buildroot is going to overwrite
    anyway.
- Root filesystem: `BR2_TARGET_ROOTFS_INITRAMFS=y`. This selects
  `BR2_TARGET_ROOTFS_CPIO` automatically, and Buildroot's kernel fixup points
  `CONFIG_INITRAMFS_SOURCE` at the generated `rootfs.cpio`, baking it into the
  kernel image at kernel-build time. `BR2_TARGET_ROOTFS_TAR` must be off --
  Buildroot's own `fs/initramfs/Config.in` warns against enabling both, since
  you would end up with two copies of the same rootfs.
  - This mechanism is unrelated to the appended-DTB code path (see
    `artifacts/bug-report-appended-uimage-dts-subdir.md`), so it does not hit
    that bug. The kernel is built twice -- once with a placeholder empty cpio,
    then rebuilt via Buildroot's `linux-rebuild-with-initramfs` target once
    the real `rootfs.cpio` exists -- which is Buildroot's normal ordering for
    this option, not something to route around. `rootfs-initramfs` is a
    `TARGETS_ROOTFS` member, so the rebuild completes before
    `BR2_ROOTFS_POST_IMAGE_SCRIPT` runs and `post-image.sh` sees the zImage
    with the initramfs already in it.
  - `CONFIG_DEVTMPFS_MOUNT` does not take effect under an initramfs; the
    kernel skips the automount. Buildroot covers this itself, installing
    `fs/cpio/init` as `/init` to mount devtmpfs and create `/dev/console`
    before `/sbin/init` runs (`fs/cpio/cpio.mk`). Nothing here needs to
    arrange it, and an absent `/dev` early in boot is not a bug to chase.
- DTB append still goes through a manual `post-image.sh` step, not
  `BR2_LINUX_KERNEL_APPENDED_UIMAGE`, for the same reason the main target
  avoids it: the DTS lives in a `hisilicon/` subdirectory, which is exactly
  the layout that trips the two-loop `basename` mismatch in Buildroot's
  `linux.mk`.
- Both DTBs are built in both configurations regardless: `LINUX_DTS_NAME` is
  derived from every `.dts` found under `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR`.
  Only the stem each `post-image.sh` names gets wrapped into a uImage, so the
  spare `.dtb` in the images directory is harmless.

## Userland / package set

The minimal DTB's hardware scope drives the package list, not a general
notion of "small": if a driver cannot bind, its userspace tool has nothing to
do. The size budget above is the second constraint on the same list. Ethernet
is the deliberate exception to the original UART-only scope.

- Dropbear uses the same host keys and root authorized key as the production
  image. The shared `post-build-ssh.sh` installs the machine-local key
  material for both targets. The outbound SSH
  client is omitted from the diagnostic image because it is not needed for the
  rescue interface and would push the payload over vendor U-Boot's limit.
- Buildroot's `BR2_SYSTEM_DHCP="eth0"` supplies the normal network init script
  and BusyBox `udhcpc`. The shared network overlay applies the unit's factory
  MAC address before DHCP, preserving its production reservation.
- The bootstrap carries only `sfdisk`, `mke2fs`, `mkfs.fat`, and `blkid` from
  the storage packages used by the provisioning scripts. Its post-build audit
  requires those commands and rejects factory-flash writers. SPI NOR, GPIO and
  I²C remain disabled in the DTB.
- Keep `BR2_INIT_BUSYBOX`, `BR2_TARGET_GENERIC_GETTY`, and the existing root
  password plumbing (`BR2_TARGET_ENABLE_ROOT_LOGIN`,
  `BR2_TARGET_GENERIC_ROOT_PASSWD="$(DHB_AX_ROOT_PASSWD)"`). Reusing
  `DHB_AX_ROOT_PASSWD` from `local.env` keeps one password to remember and
  matches the existing serial-login convention in `AGENTS.md`, rather than
  shipping a passwordless or separately-tracked credential for this image.
- `BR2_TARGET_GENERIC_HOSTNAME="minimal"`. The console login banner is the
  only thing distinguishing the two images at a glance, and the two are most
  likely to be confused in exactly the situation this image exists for. The
  main build stays `dhb-ax`; leaving this unset would give the Buildroot
  default and say nothing.
- The production overlay is split by responsibility. Both targets use
  `rootfs-overlay-network` for the pre-DHCP MAC hook; only the main target uses
  `rootfs-overlay` for HDD/USB mounts and storage module loading. The minimal
  image otherwise keeps Buildroot's skeleton `/etc/fstab` and mounts neither
  storage device automatically.
- `post-build.sh` remains specific to the main package set because it audits
  production storage tools and removes flash writers. The minimal target uses
  `post-build-minimal.sh`, which installs the shared SSH material and asserts
  its smaller storage-tool set and the absence of flash writers.
- BusyBox's `CONFIG_FEATURE_SKIP_ROOTFS` is disabled with a minimal-only
  fragment. BusyBox normally hides `rootfs` because most systems replace the
  initial root with disk or NFS; this image keeps rootfs mounted for its whole
  lifetime, so displaying it makes `df -k` accurately describe the image.

## Build tooling

- `scripts/buildroot.sh` and `scripts/buildroot-in-container.sh` currently
  hardcode `dhb_ax_defconfig`, one Docker volume pair
  (`dhb-ax-br-output`/`dhb-ax-br-dl`), and one artifacts path
  (`artifacts/buildroot`).
- The selector is a leading `--config NAME` option on `scripts/buildroot.sh`,
  consumed and shifted off before anything else parses `$1`, and passed into
  the container as an environment variable. It is *not* a bare positional
  argument: positional arguments are already make targets -- `buildroot.sh`
  hands `"$@"` straight to `br` -- and `dhb_ax_defconfig` is itself a legal
  target, special-cased in `buildroot-in-container.sh` today. Overloading a
  defconfig name to mean both "configure only" and "configure and build
  everything" is exactly the kind of ambiguity that later reads as a bug.
  `--config` also has to be parsed ahead of the existing `--help`,
  `--clean`, `--distclean`, `--shell` and curses-target checks, all of which
  inspect `$1` directly.
  - Not a `DHB_AX_*` environment variable: that prefix means a machine-local
    value read from `local.env`, and which target to build is neither.
  - Not a second wrapper script: the `docker run` invocation, its five mounts
    and the tty and read-only-remount logic would be duplicated, and the copy
    drifts the first time either is edited.
  - One short name selects all four per-config values, so there is no way to
    pair the wrong output volume with the right defconfig:

        --config          defconfig                 volume                     artifacts
        (none) / main     dhb_ax_defconfig          dhb-ax-br-output           artifacts/buildroot
        minimal           dhb_ax_minimal_defconfig  dhb-ax-br-minimal-output   artifacts/buildroot-minimal

    Accept `main` as an explicit spelling of the default so a script or a note
    can name what it builds instead of relying on the absence of a flag.
    Reject any other name rather than deriving a path from it: an unknown
    `--config` that silently configures a fresh volume is a long way to walk
    before anything complains.
- The two builds must not share an output directory. Buildroot's incremental
  build is a set of coarse per-package stamp files, not a full dependency
  graph over package content: switching `.config` under an existing output
  tree does not reliably remove files belonging to packages the new config
  deselected. This project has already hit an instance of that class of bug
  -- see `prune_disabled_images` and the "reapply defconfig every run" comment
  in `buildroot-in-container.sh` -- for a single defconfig's own toggles;
  two structurally different defconfigs sharing one output dir would be
  worse. Two output volumes keep each build's incremental cache valid,
  which is the reason a persistent volume exists here at all (bind-mounting
  Buildroot's ~100k-file output tree is slow on macOS).
  - Two *named volumes*, `dhb-ax-br-output` and `dhb-ax-br-minimal-output`,
    rather than two subdirectories of one volume. `--clean` and `--distclean`
    are `docker volume rm` calls that deliberately run before
    `require_env_file` and need no container, no `local.env` and no built
    image, so they work on a fresh checkout. Per-config subdirectories would
    turn a clean into a `docker run ... rm -rf`, which needs the image built
    first; that is a worse trade than one more entry in `docker volume ls`.
- What the separation costs is much smaller than it would be otherwise,
  because the toolchain is no longer part of it. `dhb-ax-br-output` is ~12 GB
  today, most of it the toolchain and its build tree; with both configurations
  on the shared SDK, neither output tree builds a compiler and the second tree
  is a fraction of that. What remains duplicated is each configuration's own
  package build, which is what the isolation is for. Two further things reduce
  it:
  - `dhb-ax-br-dl` stays shared. Both configurations fetch the same tarballs,
    and the staged SDK tarball lives there too.
  - A shared ccache, across all three configurations. `BR2_CCACHE=y` and
    `BR2_CCACHE_INITIAL_SETUP="--max-size=10G"` in each defconfig, backed by a
    named volume `dhb-ax-br-ccache`.
  - Two things make it worth having here that would not have been true of a
    self-built toolchain per tree. Both configurations now compile with the
    same external compiler, the same binary at the same path, so ccache
    identifies it identically and target compiles share between them --
    separately built cross compilers would have had different timestamps and
    shared nothing, since ccache identifies a compiler by timestamp and size
    by default. And the cache arrives warm: `shared-toolchain.md` requires a
    from-scratch rebuild of the production image to verify it, and with ccache
    already enabled that rebuild seeds the cache before the minimal tree is
    ever built.
  - Ordering therefore matters, and is the reason `BR2_CCACHE` belongs in
    `dhb_ax_defconfig` as part of the toolchain work rather than being added
    alongside the minimal defconfig. Enabled afterwards it would seed nothing:
    ccache fills only when a compiler runs through it, there is no import path
    from an already-built tree, and Buildroot's per-package stamps do not
    track `.config` changes -- the same coarse-stamp behaviour
    `prune_disabled_images` exists to work around -- so an already-built main
    tree will not recompile just because the option appeared.
  - `BR2_CCACHE_DIR` stays unset, at Buildroot's default of
    `$(HOME)/.buildroot-ccache`. The container's `HOME` is `/home/br`, set on
    the `setpriv` line in `buildroot-in-container.sh`, so the default already
    resolves to where `buildroot.sh` mounts the volume, and a container path
    stays out of a tracked public board defconfig. The coupling is real and
    silent, though -- move the mount or change `HOME` and ccache quietly
    writes to an unmounted directory that vanishes with the container, costing
    only build time and printing nothing. Say so at both ends: a comment on
    the mount in `buildroot.sh` naming the default it is matching, and a
    comment in the defconfig naming the volume the default lands on.
  - The ccache volume needs the same ownership fix `/output` and `/dl` already
    get. `buildroot-in-container.sh` starts as root solely to chown the named
    volumes, which Docker creates root-owned, before dropping to `br`; a
    volume left out of that loop is one the build cannot write, and ccache
    fails soft -- it degrades to no caching rather than erroring -- so the
    symptom would be a slow build and no message.
- `--clean` and `--distclean` currently name `$out_volume` and `$dl_volume`
  literally. `--clean` drops the selected config's output volume and nothing
  else -- with no `--config` that is `dhb-ax-br-output`, exactly what the
  command removes today, so an existing habit keeps its existing blast radius
  rather than quietly growing one. `--config minimal --clean` reaches the
  other one, and `--distclean` drops both output volumes, the shared download
  volume and the ccache volume. Leaving these single-volume would strand
  ~10 GB and, worse, leave a stale output tree that a later `--config` run
  silently reuses. Report by name what is being removed, as the current
  messages do -- with four volumes in play, "removing volume ..." is the only
  confirmation the right one went.
- `--shell` and the `savedefconfig` read-write remount both have to follow the
  selected config: a shell on the wrong output volume is merely confusing, but
  `savedefconfig` writes `BR2_DEFCONFIG` as recorded in that volume's
  `.config`, so running it against the wrong one rewrites the wrong tracked
  file.
- `check_defconfig` (the verification that every defconfig line survived into
  `.config`) generalises directly: it already reads the defconfig file by
  path, so it just needs that path parameterised alongside the `br
  dhb_ax_defconfig` call, and the "did we just run a defconfig target" case
  match generalised to whichever name is selected.

### post-image

- `board/dhb-ax/post-image-minimal.sh` is a second script, used only by
  `dhb_ax_minimal_defconfig`. It appends `hi3531-dhb-ax-minimal.dtb` to the
  *minimal* zImage -- which now has the initramfs baked in -- rather than to
  the main build's zImage, which is where it produces a non-bootable artifact
  today. `dhb_ax_defconfig`'s `post-image.sh` drops back to a single stem,
  `hi3531-dhb-ax`, and loses its loop.
- Two scripts means two copies of the mkimage invocation and its load and
  entry addresses. Take the kernel version out of both rather than copying
  that too: Buildroot exports `BR2_CONFIG` to post-image scripts, pointing at
  the output `.config`, so each script can read the version it is actually
  wrapping instead of carrying a literal `Linux-6.18.42` that a version bump
  has to find in two more places.

        version=$(sed -n \
            's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' \
            "$BR2_CONFIG")

  Everything else the two share -- `-A arm -O linux -T kernel -C none`,
  `-a 0x80008000 -e 0x80008000`, and the explanation of why
  `BR2_LINUX_KERNEL_APPENDED_UIMAGE` cannot be used -- is duplicated
  deliberately. `post-image-minimal.sh` should say in one line that the
  addresses and the appended-DTB reasoning are explained in `post-image.sh`,
  so the second reader knows where the argument lives rather than assuming
  the two were derived independently.

### Stale minimal outputs

Dropping the stem stops `post-image.sh` *regenerating*
`uImage-hi3531-dhb-ax-minimal` and `zImage-hi3531-dhb-ax-minimal-appended-dtb`,
but both files stay in the main output volume's `images/` directory, and the
copy loop at the end of `buildroot-in-container.sh` copies everything in
`images/` on every run -- so `artifacts/buildroot/` would keep publishing a
correctly-named, non-bootable minimal image indefinitely. That is precisely
the failure this plan exists to end, so it cannot be left to a manual
`--clean` that nobody knows to run.

Delete the two files by name from `$output/images` and `$artifacts` early in
`buildroot-in-container.sh`, in the same commit that changes the stem list.
This is a migration, not a rule, and by the repository's own convention on
deliberately temporary text it has to name what retires it: it can go once
every output volume in use has been rebuilt or cleaned since that commit.
`prune_disabled_images` is the wrong home for it -- that function answers
"is this image format still enabled", which is a standing question, and
burying a one-off migration in it would leave a permanent check with no
condition that ever makes it false.

- Output artifact: `uImage-hi3531-dhb-ax-minimal`, in its own artifacts
  subdirectory (`artifacts/buildroot-minimal/`) rather than
  `artifacts/buildroot/`, so it cannot be silently overwritten by or overwrite
  the main build's same-named files. `artifacts/` is already gitignored whole,
  so no ignore rule changes.

## Installing on USB

The `usb` subcommand loads by filename from the USB FAT partition, and
`tools/dvr-install-system.sh` writes exactly one name: `/uImage`, plus
`/uImage.sha256`. Installing the minimal image with `--kernel-only` today
would replace the production kernel, which inverts the point of a recovery
image.

`dvr-install-system.sh` needs to install the minimal image under a second
name -- `/uImage-minimal` and `/uImage-minimal.sha256` -- alongside the
production kernel rather than over it. The existing staging, checksum
verification and atomic `mv` sequence applies unchanged; only the destination
name and the source default differ. `tools/dvr-boot.sh usb uImage-minimal`
then boots it. The size budget above has to account for both images living on
that partition at once.

## Boot tooling

- `tools/dvr-boot.exp` currently only knows `--root hdd` and `--root nfs`,
  both of which append `root=`/`rootfstype=`/`rootwait` (or NFS/`ip=`)
  arguments in `configure_bootargs`. A built-in initramfs needs neither: the
  kernel mounts it automatically before any `root=` processing happens. Add a
  third mode, `--root initramfs`, which contributes no root arguments at all.
  `initramfs` rather than `ram`, because `ram` reads as a ramdisk -- an
  `initrd` loaded separately at an address -- which is not what this is.
- `configure_bootargs` needs a real empty case, not just an empty argument.
  It builds `set expected "$common_bootargs $root_bootargs"` and then compares
  that against `printenv bootargs` exactly, after right-trimming the line. An
  empty `root_bootargs` leaves a trailing space in `expected` that the board
  can never produce, so every boot would fail the verification with
  `U-Boot bootargs mismatch` and exit 7. The second
  `setenv bootargs ${bootargs} ` is also a no-op worth skipping. Branch on
  `$root_bootargs eq ""`: one `setenv`, and `expected` set to
  `$common_bootargs` with no separator.
- Split `common_bootargs`. The `libata.force=` list exists to stop libata
  spending a second per empty port-multiplier sub-port; with SATA compiled
  out it is an unknown parameter the kernel logs and passes to userspace.
  That is not fatal, but a diagnostic image whose value is a clean `dmesg`
  should not open with a complaint about parameters it deliberately does not
  implement. Keep `console=`, `earlycon=`, `ignore_loglevel` and the two
  `mem=` arguments common to all three modes; move `libata.force=` alongside
  the `root=` arguments, where the hardware it describes is actually present.
- The `ipaddr`/`netmask`/`serverip`/`ethaddr` `setenv` calls stay for
  `--root initramfs`. They are in the `tftp` branch and configure U-Boot's own
  networking so the transfer can happen; they are not root-filesystem
  arguments. Only the kernel-side `ip=` and `nfsroot=` belong to `--root nfs`.
  Dropping the U-Boot ones under the new mode would break
  `tftp ... --root initramfs`, which is one of the two ways this image is
  meant to be booted.
- Reject `usb --root initramfs` without an explicit image argument. The `usb`
  default image is `uImage` -- the production kernel -- and booting that with
  no `root=` panics. The combination is always a mistake, and it is cheap to
  say so before touching the UART rather than after a 120-second timeout.
- The `tftp` subcommand's default local image
  (`artifacts/buildroot/uImage-hi3531-dhb-ax`) stays pointed at the main
  build; booting the minimal image is `tftp
  artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal --root initramfs`,
  no new default needed.
- `dvr-boot.sh` requires `DHB_AX_DVR_ETHADDR` and the rest of the network keys
  from `local.env` unconditionally, before any subcommand is known. That is
  unchanged and fine: TFTP needs them before Linux starts, while the booted
  image obtains its userspace address independently through DHCP.

## Sequence

1. `scripts/buildroot.sh` / `buildroot-in-container.sh` parameterisation
   first: `--config` option, second output volume, shared ccache volume,
   second artifacts path, generalised `check_defconfig`, and `--clean` /
   `--distclean` / `--shell` / `savedefconfig` following the selection. The
   kernel work below has no way to build otherwise -- `buildroot.sh` passes
   no output directory through to the container, so there is no scratch-dir
   escape hatch to start from.
2. `linux-minimal.config` and `dhb_ax_minimal_defconfig`, iterated with
   `scripts/buildroot.sh --config minimal` until it produces a `rootfs.cpio`
   and a kernel with the initramfs baked in, within the size budget.
3. `post-image-minimal.sh`, dropping the `hi3531-dhb-ax-minimal` stem from
   `post-image.sh` and purging the two stale minimal outputs that leaves
   behind. Take the kernel version from `BR2_CONFIG` in both scripts while
   they are open.
4. `tools/dvr-boot.exp`: `--root initramfs`, the `configure_bootargs` empty
   case, the `common_bootargs` split, and the `usb --root initramfs` guard.
5. `tools/dvr-install-system.sh`: install the minimal image as
   `/uImage-minimal` alongside the production kernel.
6. Boot on the rig over `tftp` first -- it iterates fastest and needs nothing
   installed -- then install to USB and boot over `usb`. Confirm a login
   prompt reading `minimal login:` on the serial console with no HDD or NFS
   export involved.
7. Documentation: `README.md` for the new maintained target and its verified
   status, and the `AGENTS.md` sections on building, booting and installing.
   `local.env.example` only if a new `DHB_AX_*` key appears, which nothing
   here currently requires.

## Acceptance

- `scripts/buildroot.sh --config minimal` succeeds and
  `artifacts/buildroot-minimal/` holds `uImage-hi3531-dhb-ax-minimal` and
  `rootfs.cpio`. The uImage is within the recorded size budget.
- A rebuild of `dhb_ax_defconfig` afterwards is unaffected: its output volume
  and artifacts are unchanged by the minimal build having run,
  `artifacts/buildroot/` no longer contains `uImage-hi3531-dhb-ax-minimal` or
  `zImage-hi3531-dhb-ax-minimal-appended-dtb`, and the image it produces
  still boots to the HDD root -- verified by an actual
  `tools/dvr-boot.sh usb`, not by inspecting the artifacts.
- Both uImages carry the kernel version their own build used. `mkimage -l` on
  each reports `Linux-<version> <stem>` matching that config's
  `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE`, so the two post-image scripts are
  demonstrably not carrying a stale literal.
- `scripts/buildroot.sh --config minimal --clean` removes only
  `dhb-ax-br-minimal-output`, and a bare `--clean` removes only
  `dhb-ax-br-output`; in each case a subsequent build of the *other* config is
  still incremental. `--distclean` removes both output volumes,
  `dhb-ax-br-dl` and `dhb-ax-br-ccache`. All three work on a checkout with no
  `local.env`.
- The ccache is shared and being used: `check_defconfig` reports `BR2_CCACHE`
  present for every defconfig, `ccache -s` inside `--shell` shows a non-zero
  cache size on the mounted volume -- not an empty cache in an unmounted
  directory, which is how the `HOME` coupling above fails -- and the first
  minimal build reports a non-zero hit rate, drawing on what the production
  rebuild in `shared-toolchain.md` left behind.
- `tools/dvr-boot.sh usb uImage-minimal --root initramfs` and
  `tools/dvr-boot.sh tftp artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal --root initramfs`
  both reach a `minimal login:` prompt on the serial console, obtain the
  production DHCP reservation and accept the production authorized SSH key,
  with the HDD left unmounted and no writes to board storage (no `saveenv`,
  matching the existing boot-tooling constraints).
- `tools/dvr-boot.sh usb --root initramfs`, with no image named, exits with a
  usage error before opening the UART. The same is true of `tftp --root
  initramfs` without a local image.
- BusyBox has `CONFIG_FEATURE_SKIP_ROOTFS` disabled, so `/proc/mounts` and
  `df -k` expose the initramfs as `rootfs` instead of hiding it.
- The trim is verified against the *artifact*, not the boot log. `dmesg`
  silence proves nothing here: a platform driver only probes when an enabled,
  matching DT node exists, so the current full-config-plus-minimal-DTB image
  already produces exactly that dmesg. Instead:
  - `grep -E 'ahci|pl061|i2c_gpio|ehci|ohci' /proc/kallsyms` on the booted
    image returns nothing. `stmmac`, the Hi3531 DWMAC glue and the Realtek PHY
    driver are present for the one enabled data-path peripheral.
  - The diff between the two built `.config` files shows the intended drivers
    off, and shows `CONFIG_ARM_APPENDED_DTB`,
    `CONFIG_ARM_ATAG_DTB_COMPAT_CMDLINE_FROM_BOOTLOADER`,
    `CONFIG_BLK_DEV_INITRD` and the hi3531 platform symbols still on.
  - The minimal `zImage` is materially smaller than the main build's, by an
    amount recorded alongside the size budget.

## Execution results (initial UART-only image, 2026-08-23)

The maintained minimal target builds cleanly and boots from both supported
load paths. Its artifacts are:

- `rootfs.cpio`: 1,781,248 bytes.
- `zImage`: 2,537,656 bytes.
- `uImage-hi3531-dhb-ax-minimal`: 2,544,243 bytes, SHA-256
  `4de5467596964cb07e7b376d4128c30ab0fe0824fac21eca93f8746b92d7e295`.
- Legacy image title: `Linux-6.18.42 dhb-ax-minimal`. The planned full stem
  does not fit U-Boot's 32-byte legacy image-name field, so the artifact keeps
  the full stem while the embedded title uses the shorter board name.

The production `zImage` from the regression build is 3,559,792 bytes, making
the minimal kernel 1,022,136 bytes smaller. The clean minimal build reused the
shared compiler cache: 24,506 of 39,862 cacheable calls were hits (61.48%),
with 0.2 GB stored in the shared 10 GB cache.

The final USB and TFTP boots both reached `minimal login:` with this command
line and no root-device arguments:

```
console=ttyAMA0,115200 earlycon=pl011,0x20080000 ignore_loglevel mem=512M@0x80000000 mem=512M@0xc0000000
```

Runtime evidence was `Total pages: 262144`, `MemTotal: 1036056 kB`, and
`rootfs / rootfs rw`; the forbidden-driver kallsyms check returned no matches.
Because this is a built-in initramfs rather than an externally loaded initrd,
the relevant release line is `Freeing unused kernel image (initmem) memory:
1104K`; there is no separate `Freeing initrd memory` line. The final clean
image starts syslog, klog, sysctl and crond only, with no network startup.

Both load paths reject `--root initramfs` when no image is named. Their
defaults select the production kernel, which has no built-in initramfs and
would otherwise panic after booting without a `root=` argument.

USB installation left the production `/uImage` in place and installed the
diagnostic image and checksum as `/uImage-minimal` and
`/uImage-minimal.sha256`. TFTP transferred the same 2,544,243-byte image after
a hard reset cleared the vendor U-Boot PHY state. A warm reboot can instead
end in `PHY not link!`; the boot tool reports the required hard-reset recovery.

After both diagnostic boot paths, the production regression boot reported
Linux 6.18.42, hostname `dhb-ax`, and `/dev/root / ext4 rw,relatime`. The main
artifact directory contains only the production uImage stem, and the
configuration-specific clean/distclean volume selection was verified without
removing the shared downloads or compiler cache during a per-target clean.

### Networked diagnostic extension (2026-08-23)

The diagnostic image now enables only the board's Ethernet data path in
addition to its original CPU/timer/UART scope. Buildroot starts BusyBox
`udhcpc` for `eth0`, followed by Dropbear; the shared pre-up hook applies
the factory MAC before DHCP, and both images share the same Dropbear host keys
and root authorized key. The outbound SSH client is deliberately absent.
BusyBox's `CONFIG_FEATURE_SKIP_ROOTFS` is off,
so the permanent initramfs mount is visible to `df`.

The final clean-build artifacts are:

- `rootfs.cpio`: 10,841,088 bytes.
- `zImage`: 7,292,320 bytes.
- Appended zImage and DTB payload: 7,299,023 bytes, 1,056,817 bytes below the
  vendor U-Boot ceiling.
- `uImage-hi3531-dhb-ax-minimal`: 7,299,087 bytes, SHA-256
  `c4e8f105b134b8ab1237ac0a7f328609ef672e846eb1c1a9cc4d29dddcf9a481`.

The size check came from a failed hardware test, not an estimate: the first
networked payload was 8,589,199 bytes and U-Boot rejected it with `kernel image
will overwrite uboot`. `post-image-minimal.sh` now fails the build before
`mkimage` when the payload is at least 8,355,840 bytes. The boot helper also
waits for the hostname appropriate to the selected root mode and reports a
U-Boot overlap or board reset instead of accepting a later vendor login prompt
as success.

The final TFTP boot reached `minimal login:`. Ethernet linked at 1 Gbit/s,
DHCP assigned `192.168.4.77/22` with the factory MAC, and public-key SSH
succeeded using the established host identity. Runtime checks reported:

```
hostname=minimal
kernel=6.18.42
rootfs / rootfs rw,size=514692k,nr_inodes=128673 0 0
rootfs 514692 10700 503992 2% /
```

The live forbidden-driver check found none of `ahci`, `pl061`, `i2c_gpio`,
`ehci` or `ohci`; `stmmac`, the Hi3531 DWMAC glue and RTL8211B PHY were active.
The generated root contained no kernel modules or storage device setup. A main
image rebuild after splitting the network overlay and SSH post-build script
also passed its defconfig, post-build safety audit and image generation.

The first long regression attempt began after vendor Linux had run. That
environment later reset both the main and minimal mainline kernels at an
interval consistent with the front-panel MCU watchdog. After a physical hard
reset, the final TFTP image remained reachable over one continuous SSH session
through 113 seconds of uptime, beyond the earlier reset interval. A subsequent
warm transition through the main image left U-Boot reporting its known
Ethernet PHY-link-down condition, so another physical hard reset is required
before the requested final TFTP boot. The networked image was deliberately not
installed to USB; this validation leaves the production USB files unchanged.

### Storage-bootstrap extension (2026-08-23)

The minimal image now carries the built-in SATA/AHCI and USB-storage paths plus
the partitioning and filesystem tools used to prepare the approved HDD and USB
drive. A first hardware installation found that FAT needs its default CP437
codepage at mount time, so NLS CP437 and ISO-8859-1 are built in alongside
FAT/VFAT. The rebuilt initramfs mounted the prepared USB successfully and
completed production installation. The installed USB kernel and HDD ext4 root
then booted Linux 6.18.42 and accepted its established SSH key. The detailed
artifact hashes and provisioning results are recorded in
`plans/minimal-as-bootstrap.md`.
