# Buildroot migration plan

Status: **plan only**, for review before execution. Written 2026-08-04 on the
`buildroot` branch. The last state known to boot is tagged `pre-buildroot`.

Companion to `../kernel-port/README.md`, which holds the current build and the
hardware evidence this plan is validated against.

## Why

Two reasons, and only one of them is about past friction.

**The next work needs tools we cannot easily provide.** Read-only SPI NOR and
NAND access requires `mtd-utils` — `mtdinfo`, `nanddump`, `flash_erase` — which
has dependencies and is unpleasant to cross-compile by hand. Several deferred
questions need `ethtool` (TX checksum offload, PHY master/slave state) and
`i2c-tools`. The current userspace is one prebuilt Debian `busybox-static`
binary and twenty-eight symlinks.

**The bespoke tooling exists to solve a problem Buildroot does not have.**
`build-in-container.sh` applies the patch queue *in place* to a persistent
tree, so it needs a reverse-apply idempotency check to be re-runnable. That
check is also what failed mid-session when a stale tree carried a superseded
patch that could neither apply nor reverse, which is why
`bootstrap-sources.sh --reset-build` exists. Buildroot extracts a fresh tree
and applies patches once; the whole class of problem disappears along with the
two workarounds.

Note what is *not* the argument. The accumulated annoyances — 32-bit `time_t`
breaking `ls` on the DVR disk, the missing `/sbin/modprobe`, the unpinned
BusyBox — cost well under an hour in total and none blocked anything. They are
real but minor, and would not on their own justify this.

## What Buildroot replaces

| Today | Under Buildroot |
|---|---|
| `bootstrap-sources.sh` fetches and derives trees | `BR2_LINUX_KERNEL_CUSTOM_TARBALL`, managed automatically |
| Patch queue applied in place, with an idempotency check | Patch directory applied to a fresh tree |
| Three drivers copied in, their Kconfig hooks as patches | Twelve uniform patches, one mechanism |
| DTS files copied into the kernel tree | `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` |
| Kconfig seed plus `scripts/config` edits | `BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE` |
| Initramfs hand-assembled with `ln -s` per applet | `BR2_TARGET_ROOTFS_CPIO` plus a rootfs overlay |
| `mkimage` invoked by hand, DTB appended with `cat` | `BR2_LINUX_KERNEL_APPENDED_UIMAGE` |
| Module tarball built by a shell loop | Standard |
| Debian `busybox-static` unpacked from a `.deb` | BusyBox built from source, with our flags |

Option names above are from memory and must be confirmed against the pinned
Buildroot release before being relied on.

## What stays

- **Docker.** Buildroot needs Linux; the Mac does not run it natively. The
  existing container becomes the host for Buildroot rather than for a bespoke
  script.
- **The patches and drivers themselves.** These are the actual work product.
  They move and change form, not content.
- **`kernel-port/reference/`.** The vendor runtime probe, the chip survey and
  the hardware write-up are evidence, not build machinery.
- **The external toolchain.** Point Buildroot at the Debian
  `arm-linux-gnueabihf` cross-compiler already in the container rather than
  building one from source. This is the difference between a few minutes and
  most of an hour on first build.

## Target layout

Buildroot's own mechanism for out-of-tree board support is a `BR2_EXTERNAL`
tree. Buildroot itself is fetched and pinned, never vendored or forked.

```text
board/                          BR2_EXTERNAL tree
  external.desc                 names the tree
  external.mk
  Config.in
  configs/
    dhb_ax_defconfig            the Buildroot configuration
  dhb_ax/
    linux.config                kernel configuration
    patches/linux/              the twelve patches
    dts/                        hi3531-dhb-ax*.dts, .dtsi
    rootfs-overlay/             /init and anything hand-placed
    post-build.sh               if needed
```

Pin Buildroot at **2026.02.3** — the `.02` releases are the LTS line, which
suits a project that will be picked up intermittently.

## Stages

Each stage is independently verifiable and leaves a working build behind.
`kernel-port/build.sh` keeps working until the final stage removes it.

### Stage 1 — convert the drivers to patches

Turn `dwmac-hi3531.c`, `ahci_hi3531.c` and `phy-hi3531-usb.c` into
file-adding patches, merged with their existing Kconfig and Makefile patches
so each driver is one patch rather than a copied file plus a separate hunk.

**This has to happen regardless of Buildroot** and is independently useful.

*Acceptance:* the existing `kernel-port/build.sh` still produces a kernel that
boots and passes the checks below. The DTB should be byte-identical; the
kernel image will not be, because the legacy uImage header carries a
timestamp.

### Stage 2 — Buildroot skeleton, no output yet

Fetch and pin Buildroot in `bootstrap-sources.sh`. Create the `BR2_EXTERNAL`
tree, the defconfig, and the external toolchain wiring. Add Buildroot's
download cache and output directory to `.gitignore`.

*Acceptance:* `make dhb_ax_defconfig` succeeds and `make` gets as far as
configuring the kernel.

### Stage 3 — kernel from Buildroot

Move the kernel config, DTS and patches under `board/`. Configure the
appended-DTB uImage with the load and entry address `0x80008000`.

*Acceptance:* the produced `uImage` boots to a shell over TFTP and passes the
full check list. Compare against the `pre-buildroot` build.

### Stage 4 — userspace from Buildroot

BusyBox from source, replacing the Debian binary. Build with 64-bit `time_t`,
which requires 64-bit file offsets alongside it — glibc rejects `_TIME_BITS=64`
without `_FILE_OFFSET_BITS=64`. Add the tools the roadmap needs:

- `mtd-utils` — required for the flash work
- `ethtool` — TX checksum offload, PHY master/slave state
- `i2c-tools` — the bit-banged bus and the DS1307
- `e2fsprogs`, `dosfstools` — read-only inspection of the DVR disk
- Optionally `iperf3`, `fio`, `smartmontools` for measurement

*Acceptance:* `ls` on the DVR's FAT32 partitions no longer reports
`Value too large for defined data type`, which is the visible proof that
`time_t` is now 64-bit. All hardware checks still pass.

### Stage 5 — validate against known-good

Run the full check list, comparing against the numbers recorded in
`kernel-port/README.md`. Only then merge to `main`.

### Stage 6 — retire the old path

Remove `build-in-container.sh` and the parts of `bootstrap-sources.sh`
Buildroot has taken over. Rewrite the build sections of both READMEs. Separate
commit, after the merge, so a revert is clean.

## Acceptance checks

The evidence that must hold at Stage 3 and again at Stage 5. Numbers are from
the `pre-buildroot` build.

| Check | Expected |
|---|---|
| Boots to shell over TFTP | BusyBox prompt on the serial console |
| Both cores | `/proc/cpuinfo` reports 2; IPI counters advance on CPU1 |
| Ethernet | link up at 1 Gbps; 20000-packet flood at 0% loss |
| SATA | port multiplier enumerates; `sda` with 4 partitions |
| FAT32 | read-only mount succeeds; a chunk's MD5 matches over NFS |
| USB high speed | Flash Voyager, ~33 MB/s sustained, both sockets |
| USB full speed | FTDI appears as `/dev/ttyUSB0` |
| GPIO | 19 `/dev/gpiochip*` devices |
| Wall clock | DS1307 sets a real date at boot, not 1970 |
| Reset | `echo b > /proc/sysrq-trigger` returns to U-Boot |
| Serial rescue | BREAK then a sysrq key responds |
| Boot log | no `WARNING`, `BUG:` or `Oops` |

## Risks

**The migration stalls half-done.** Mitigated by staging: every stage leaves a
working build, and `kernel-port/build.sh` keeps working until Stage 6.

**Buildroot's kernel handling differs subtly** — patch order, config fragment
merging, or DTS placement. Stage 3 exists to surface that before userspace is
involved.

**Slower iteration.** Buildroot rebuilds more eagerly than a targeted `make`.
`make linux-rebuild` stays quick; rootfs changes are slower. Worth measuring
at Stage 4 rather than assuming.

**Rollback:** `git checkout main`, or `git checkout pre-buildroot` for the
exact known-good tree. Nothing on this branch touches the DVR.

## Open questions

- Does the pinned Buildroot's external-toolchain support accept the Debian
  `gcc-arm-linux-gnueabihf` in the container as-is, or does it want a
  self-contained toolchain directory?
- Does `BR2_LINUX_KERNEL_APPENDED_UIMAGE` produce exactly the layout the
  vendor U-Boot expects — zImage with DTB appended, wrapped in a legacy uImage
  at `0x80008000`? If not, a post-image script reproduces what
  `build-in-container.sh` does today.
- Should the two variants (`minimal`, `ethernet`) remain? The minimal variant
  was the original proof the board boots and is now a fallback that nothing
  uses. Two Buildroot defconfigs would carry it forward; dropping it removes a
  maintenance burden and a safety net at the same time.
- Is an NFS-mounted root worth adding alongside the initramfs, now that
  networking is reliable? It would remove the size pressure that currently
  argues against including larger tools.
