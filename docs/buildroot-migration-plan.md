# Buildroot migration plan

Status: **Stages 1-5 done, Stage 6 pending.**
Written 2026-08-04 on the
`buildroot` branch. The last state known to boot is tagged `pre-buildroot`.
Stage 2 touches no hardware; Stages 1 and 3 are boot-tested on the board.

Buildroot now produces a kernel that boots and passes the check list, so the
migration's central risk is retired. `kernel-port/build.sh` still works and
still produces the reference image.

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
| ~~Three drivers copied in, their Kconfig hooks as patches~~ done in Stage 1 | Nine uniform patches, one mechanism |
| DTS files copied into the kernel tree | `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH` |
| Kconfig seed plus `scripts/config` edits | `BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE` |
| Initramfs hand-assembled with `ln -s` per applet | `BR2_TARGET_ROOTFS_CPIO` plus a rootfs overlay |
| `mkimage` invoked by hand, DTB appended with `cat` | `BR2_LINUX_KERNEL_APPENDED_UIMAGE` |
| Module tarball built by a shell loop | Standard |
| ~~Debian `busybox-static` unpacked from a `.deb`~~ | BusyBox 1.37.0 from source; already working as of Stage 2 |

Option names above were written from memory. All four kernel ones were checked
against 2026.02.3 at Stage 2 and are correct as written:
`BR2_LINUX_KERNEL_CUSTOM_TARBALL`, `BR2_LINUX_KERNEL_CUSTOM_DTS_PATH`,
`BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE`, `BR2_LINUX_KERNEL_APPENDED_UIMAGE`.
The DTS one has a companion, `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR`, which is the
better fit here — see *Target layout*.

## What stays

- **Docker.** Buildroot needs Linux; the Mac does not run it natively. The
  existing container becomes the host for Buildroot rather than for a bespoke
  script.
- **The patches and drivers themselves.** These are the actual work product.
  They move and change form, not content.
- **`kernel-port/reference/`.** The vendor runtime probe, the chip survey and
  the hardware write-up are evidence, not build machinery.
- ~~**The external toolchain.**~~ Reversed at Stage 2 after testing — see
  *The toolchain* below. Buildroot builds its own.

## Target layout

Buildroot's own mechanism for out-of-tree board support is a `BR2_EXTERNAL`
tree. Buildroot itself is fetched and pinned, never vendored or forked.

```text
br2-external/                   BR2_EXTERNAL tree
  external.desc                 names the tree
  external.mk
  Config.in
  configs/
    dhb_ax_defconfig            the Buildroot configuration
  board/dhb_ax/
    linux.config                kernel configuration
    patches/linux/              the nine patches
    dts/hisilicon/              hi3531-dhb-ax*.dts, .dtsi
    rootfs-overlay/             /init and anything hand-placed
scripts/                        the containerised build
  Dockerfile
  buildroot.sh                  macOS wrapper
  buildroot-in-container.sh
buildroot/                      fetched source; gitignored
```

Two departures from the sketch above, both settled at Stage 2:

- The external tree is `br2-external/`, not `board/`. Buildroot's own
  convention puts `board/<device>/` *inside* the external tree, so naming the
  root `board/` would have produced `board/dhb_ax/` meaning something
  different from `board/` in every Buildroot example.
- `dts/` has a `hisilicon/` subdirectory because
  `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR` rsyncs the tree into
  `arch/arm/boot/dts/` preserving structure — and patch 0001 already adds
  the DTBs to `arch/arm/boot/dts/hisilicon/Makefile`. Matching the kernel's
  own layout means the patch needs no change.

Pin Buildroot at **2026.02.3** — the `.02` releases are the LTS line, which
suits a project that will be picked up intermittently.

## Stages

Each stage is independently verifiable and leaves a working build behind.
`kernel-port/build.sh` keeps working until the final stage removes it.

### Stage 1 — convert the drivers to patches — **DONE 2026-08-04**

Turn `dwmac-hi3531.c`, `ahci_hi3531.c` and `phy-hi3531-usb.c` into
file-adding patches, merged with their existing Kconfig and Makefile patches
so each driver is one patch rather than a copied file plus a separate hunk.

**This has to happen regardless of Buildroot** and is independently useful.

*Acceptance:* the existing `kernel-port/build.sh` still produces a kernel that
boots and passes the checks below. The DTB should be byte-identical; the
kernel image will not be, because the legacy uImage header carries a
timestamp.

**Outcome.** Patches 0003, 0007 and 0009 now each add their driver as a new
file alongside its Kconfig and Makefile hunks. `kernel-port/drivers/` is gone
and `build-in-container.sh` no longer copies sources; the DTS files are still
installed by the script, which Stage 3 replaces.

Verified:

- full build from a tree reset with `bootstrap-sources.sh --reset-build`, so
  the patches are the only source of the drivers
- applied sources byte-identical to the removed originals
- repeat build reports `already applied` for all nine patches — the
  idempotency check still works, which was the risk with file-adding patches
- booted over TFTP and passed every acceptance check below except the two
  needing hardware that was not attached (USB full speed) or not exercised
  (serial rescue)

### Stage 2 — Buildroot skeleton — **DONE 2026-08-04**

Fetch and pin Buildroot in `bootstrap-sources.sh`. Create the `BR2_EXTERNAL`
tree, the defconfig, and the toolchain wiring. Add Buildroot's download cache
and output directory to `.gitignore`.

*Acceptance:* `make dhb_ax_defconfig` succeeds and `make` gets as far as
configuring the kernel.

**Outcome.** Overshot the acceptance criterion — the build ran to completion,
producing an ARM `zImage` and a BusyBox `rootfs.tar`. Buildroot 2026.02.3 is
pinned by SHA-256 (`5a59e750…c7fb`, checked against the release's PGP-signed
manifest) and extracted by `bootstrap-sources.sh`.

Verified:

- `make dhb_ax_defconfig` succeeds and every setting survives into `.config`
- toolchain built from source: gcc 14.3.0, glibc 2.42, binutils 2.44,
  headers from the same 6.18.42 tarball the kernel is built from
- kernel configures and compiles with `arm-buildroot-linux-gnueabihf-`;
  output is a valid `Linux kernel ARM boot executable zImage`
- BusyBox 1.37.0 builds from source, which Stage 4 wanted anyway
- **the produced kernel config differs from the known-good one by 23 lines,
  all accounted for** — see below
- a second `make` takes 7.7 s and reproduces a byte-identical `zImage`, so
  the Docker named volume genuinely persists the toolchain

The 23-line config difference, in full: compiler identity and the
`CONFIG_CC_HAS_*` capability symbols derived from it (gcc 14.3 rather than
Debian's 12.2 — which incidentally clears
`CONFIG_GCC_ASM_GOTO_OUTPUT_BROKEN`); four `CONFIG_INITRAMFS_*` sub-options
that vanish because `CONFIG_INITRAMFS_SOURCE` was blanked; `CONFIG_GCC_PLUGINS`,
which Buildroot disables deliberately in `LINUX_BUILD_CMDS`; and
`CONFIG_AHCI_HI3531`, `CONFIG_DWMAC_HI3531` and `CONFIG_PHY_HI3531_USB`,
which do not yet exist because the patch queue is not applied. That last
group is precisely Stage 3's job.

Nothing was enabled unexpectedly. The concern recorded under *Open questions*
— that `olddefconfig` would silently turn on a great deal — does not
materialise **provided a full `.config` is fed in rather than a
`savedefconfig`**. Keep it that way.

Not done here, deliberately: no DTS, no patch queue, no appended-DTB uImage.
The image this stage produces is not bootable on the board and was never
sent to it.

### Stage 3 — kernel from Buildroot — **DONE 2026-08-04**

Move the DTS and the patch queue under `br2-external/board/dhb_ax/`; the
kernel config is already there. Configure the appended-DTB uImage with the
load and entry address `0x80008000`. One defconfig only — see Decisions taken.

Keep `linux.config` a **full `.config`**, not a `savedefconfig`. Buildroot
copies it into place and runs `olddefconfig`, which fills any absent symbol
with its Kconfig default — the opposite of the `KCONFIG_ALLCONFIG` plus
`allnoconfig` the old build uses, where absent means *no*. A minimal
defconfig fed through that would enable a great deal, silently.

*Acceptance:* the produced `uImage` boots to a shell over TFTP and passes the
full check list. Compare against the `pre-buildroot` build.

**Outcome.** Boots to a shell and passes every check that the attached
hardware allows — 11 of 13. The two skipped are the same two Stage 1 skipped:
no USB stick and no FTDI adapter were plugged in.

| Check | Result |
|---|---|
| Boots to shell over TFTP | BusyBox prompt on the serial console |
| Memory | `MemTotal` 513,144 kB — 4 kB under the reference, one page, from a slightly larger kernel |
| Both cores | `Brought up 2 CPUs`; `/proc/cpuinfo` reports 2 |
| Ethernet | `Link is Up - 1Gbps/Full`; 20000 packets, 0% loss |
| SATA | JMicron `0x197b:0x0325` multiplier enumerated; `sda` with 4 partitions |
| FAT32 | read-only mount; 8 MiB chunk MD5 `da3d0110…6d89` matched over NFS |
| USB high speed | **not tested** — nothing attached |
| USB full speed | **not tested** — nothing attached |
| GPIO | 19 `/dev/gpiochip*` |
| Wall clock | real date from the DS1307, not 1970 |
| Reset | `echo b > /proc/sysrq-trigger` returned to U-Boot |
| Serial rescue | BREAK then `b` — used for real, to recover from the panic below |
| Boot log | 0 `WARNING`, `BUG:` or `Oops` |

**The device tree is byte-identical to the old build's**
(`eb45cceec28d4ae5034177cdd342bbafa0e0e97ded56a207e7353e7bb5ebcd58`), and the
kernel config differs from the known-good one by a single meaningful line —
`CONFIG_INITRAMFS_SOURCE`, which Buildroot points at its own cpio. Everything
else is compiler identity.

Three things had to be solved that the plan did not anticipate:

1. **Patch 0002 was broken** and the old build's patch fuzz was hiding it.
   See *Decisions taken*.
2. **`BR2_LINUX_KERNEL_APPENDED_UIMAGE` cannot be used.** Its
   `LINUX_APPEND_DTB` runs two loops over `LINUX_DTS_NAME`: the `cat` loop
   applies `basename`, the `mkimage` loop does not. With device trees in a
   `hisilicon/` subdirectory — which they must be, so patch 0001 keeps
   working — mkimage is handed `uImage.hisilicon/hi3531-dhb-ax`, a path whose
   directory does not exist. The kernel is built as a plain zImage and
   `board/dhb_ax/post-image.sh` does the append and wrap instead, with the
   same arguments the old build used. This is the post-image script the plan
   allowed for, needed for a different reason than expected.
3. **Buildroot's BusyBox omits `cttyhack`.** `/init` ends with
   `setsid cttyhack sh`; without it the exec failed, `/init` exited, and the
   kernel panicked with `Attempted to kill init!` — leaving the board wedged
   and needing BREAK plus sysrq to recover. Fixed with a BusyBox config
   fragment. `/init` no longer uses `exec` for the shell either, so a future
   failure of this kind leaves a usable console instead of a panic.

Also note: `ls -l` on the FAT32 partition now shows dates past 2038 with no
`Value too large for defined data type`, which is **Stage 4's acceptance
criterion, already met** — and met with `BR2_TIME_BITS_64` still unset. Set it
explicitly at Stage 4 anyway rather than relying on a default.

Modules now ship inside the initramfs, all 17 of them including
`ahci_hi3531.ko`. The old build needed them pushed over NFS before SATA could
be probed.

### Stage 4 — userspace from Buildroot

BusyBox from source is already done — it arrived at Stage 2 and has been
running on the board since Stage 3. What remains is `BR2_TIME_BITS_64` (set it
explicitly, even though the symptom it targets has already gone) and the
packages below.

Add the tools the roadmap needs:

- `mtd-utils` — required for the flash work
- `ethtool` — TX checksum offload, PHY master/slave state
- `i2c-tools` — the bit-banged bus and the DS1307
- `e2fsprogs`, `dosfstools` — read-only inspection of the DVR disk
- Optionally `iperf3`, `fio`, `smartmontools` for measurement

*Acceptance:* `ls` on the DVR's FAT32 partitions no longer reports
`Value too large for defined data type`, which is the visible proof that
`time_t` is now 64-bit. All hardware checks still pass.

**DONE 2026-08-04.** Booted and passed the same 11 of 13 checks as Stage 3,
with identical results where comparable — `MemTotal` 513,144 kB, 20000 packets
at 0% loss, the same disk and partitions, and the FAT32 chunk producing the
same MD5 `da3d0110…6d89`. Boot log clean: 0 `WARNING`, `BUG:` or `Oops` across
415 lines. USB high and full speed remain untested for want of anything
plugged in.

The acceptance criterion is met: `ls -l` on the FAT32 partition prints
`Jan 1 2098` rather than `Value too large for defined data type`.

New tools confirmed working on the board:

| Tool | Result |
|---|---|
| `ethtool eth0` | `Speed: 1000Mb/s`, `Duplex: Full`, `Link detected: yes` |
| `ethtool -k eth0` | `tx-checksumming: off`, `rx-checksumming: off [requested on]` |
| `i2cdetect` | `/dev/i2c-0` present |
| `mtdinfo` | `MTD is not present in the system` — correct; no flash driver yet |
| `debugfs`, `fsck.fat` | present |

The writers were checked on the running board, not just in the archive: none
of `mke2fs`, `e2fsck`, `flash_erase`, `flashcp`, `nandwrite`, `mkfs.fat` or
`ubiformat` is on `PATH`.

That `rx-checksumming: off [requested on]` is worth a note for the roadmap's
TX-offload question — the driver asked for RX checksum and the hardware
refused, matching the boot line `RX IPC Checksum Offload disabled`.

Two things about tool selection are worth knowing before touching this again:

- **`mtd`'s sub-options default to `y`.** Selecting `BR2_PACKAGE_MTD` alone
  installs `flash_erase`, `flashcp`, `nandwrite`, `ubiformat` and the rest.
  Naming the three read-only tools we wanted achieved nothing, because they
  were already on; the writers have to be switched off by name. The same is
  true of `e2fsprogs`, and `mke2fs` has no symbol at all — it ships with the
  base package regardless.
- **Deselecting a package does not remove what it already installed.**
  `target/` keeps the old binaries, so a config change alone leaves them in
  the image. `post-build.sh` deleted thirteen such files on the first run
  after the writers were switched off.

`post-build.sh` therefore both prunes and *asserts*: it fails the build if any
writer survives, or if any of the read-only tools has gone missing. That is
the mechanism the flash work depends on, so it should not be weakened.

### Stage 5 — validate against known-good — **DONE 2026-08-04**

Run the full check list, comparing against the numbers recorded in
`kernel-port/README.md`. Only then merge to `main`.

**Outcome.** The check list was run against the Buildroot image at Stage 3 and
again at Stage 4. Every comparable number matches the `pre-buildroot` build:

| | `pre-buildroot` | Buildroot |
|---|---|---|
| DTB sha256 | `eb45ccee…cd58` | `eb45ccee…cd58` — identical |
| `MemTotal` | ~513,148 kB | 513,144 kB (one page, larger kernel) |
| CPUs | 2 | 2 |
| Ethernet | 1 Gbps, 20000 at 0% loss | same |
| SATA | PMP, `sda` + 4 partitions | same |
| FAT32 chunk MD5 | matched over NFS | `da3d0110…6d89`, matched |
| GPIO | 19 | 19 |
| Boot log | clean | clean |

The kernel configuration differs from the known-good one by a single
meaningful line — `CONFIG_INITRAMFS_SOURCE` — with the rest being compiler
identity. Two checks (USB high and full speed) have never been run on the
Buildroot image because nothing was plugged in; they are the only gap, and
Stage 1 had the same gap.

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
| Memory | `MemTotal` ~513,148 kB (~501 MiB); boot line reads `/524288K` |
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

## Decisions taken

**The `minimal` variant is dropped.** It was the original proof that the board
boots and nothing has used it since Ethernet worked. One Buildroot defconfig,
not two. The `pre-buildroot` tag still contains it if it is ever wanted, and
`kernel-port/` on `main` keeps building it until Stage 6.

**The toolchain is built from source, not reused.** The plan originally
assumed Buildroot could point at the Debian `arm-linux-gnueabihf` compiler
already in the container. It cannot. Both external options were tried at
Stage 2 and both are closed:

- Debian's compiler is **rejected by design**. Buildroot inspects `gcc -v`
  for `--with-sysroot=/` and refuses any toolchain configured that way:
  *"Distribution toolchains are unsuitable for use by Buildroot"*
  (`toolchain/helpers.mk:458`). Getting that far also needs
  `libc6-dev-armhf-cross`, without which sysroot detection — which resolves
  `gcc -print-file-name=libc.a` — returns a path relative to the working
  directory. Neither point is a missing dependency; the block is deliberate.
- **Bootlin's prebuilt toolchains are x86_64 binaries.**
  `BR2_TOOLCHAIN_EXTERNAL_BOOTLIN` carries `depends on BR2_HOSTARCH =
  "x86_64"`, and the container is aarch64 on an Apple Silicon host. The
  symbol does not exist, so selecting it does nothing — silently, which is
  the trap described under *Risks*.

Building the toolchain costs time once. The output tree lives in a Docker
named volume that survives between runs, so it is not paid again. glibc is
the C library, because `BR2_TIME_BITS_64` — the 64-bit `time_t` that Stage 4
needs — depends on it.

**NFS root is deferred, not rejected.** Three reasons:

1. *One variable at a time.* Each stage validates against `pre-buildroot`
   numbers. Changing the root filesystem model during the migration would mean
   a failed check has two possible causes.
2. *It changes the failure model.* The board currently boots a self-contained
   RAM image, so a network failure still leaves a usable shell. With NFS root
   a network failure is a dead system -- and the thing needing debugging is
   the network.
3. *Deferring costs nothing.* Buildroot assembles `target/` and then packages
   it, so the directory is available for NFS export whether or not an
   initramfs is built. Adding NFS root later is a boot-argument change plus an
   export.

Size is **not** a reason either way, contrary to an earlier claim in this
document. The board has 501 MiB usable, the current image is about 4 MiB, and
the Stage 4 tools plausibly add 8-12 MiB compressed. There is no pressure at
this scale, and the fast-iteration benefit is largely already banked: NFS is
mounted at `/mnt` and modules are pushed over it today.

## Risks

**The migration stalls half-done.** Mitigated by staging: every stage leaves a
working build, and `kernel-port/build.sh` keeps working until Stage 6.

**Buildroot's kernel handling differs subtly** — patch order, config fragment
merging, or DTS placement. Stage 3 exists to surface that before userspace is
involved.

**Slower iteration.** Buildroot rebuilds more eagerly than a targeted `make`.
`make linux-rebuild` stays quick; rootfs changes are slower. Worth measuring
at Stage 4 rather than assuming.

**The old build tolerated a broken patch; Buildroot does not.** Buildroot
applies patches with `patch -F0` — zero fuzz. `build-in-container.sh` used
GNU patch's default fuzz of 2, which had been silently absorbing a defect in
patch 0002 for the whole life of the port: one space too many on a context
line, and a hunk header pointing one line early. With fuzz, patch slid over
both; with `-F0` the hunk was rejected outright.

Regenerated 2026-08-04 against pristine 6.18.42, and the result verified
byte-identical to the tree the working kernel was built from. All nine
patches now apply at zero fuzz — checked, not assumed. This is a real defect
found by the migration, not a Buildroot quirk to work around.

Consequence for anyone with an existing tree: the regenerated patch will not
reverse-apply against a tree carrying the old revision, so
`bootstrap-sources.sh --reset-build` is required once.

**A defconfig setting can go missing without a word.** kconfig drops any line
whose symbol does not exist or whose dependencies are unmet, and prints
nothing. That is how the first Stage 2 toolchain selection vanished — the
build ran on happily with a completely different toolchain. Guarded now:
`scripts/buildroot-in-container.sh` diffs the defconfig against the resulting
`.config` after every `dhb_ax_defconfig` and fails on any line that did not
survive. It has caught three real problems since: the Bootlin toolchain, then
`BR2_PACKAGE_I2C_TOOLS` (hidden behind `BR2_PACKAGE_BUSYBOX_SHOW_OTHERS`), then
an `is not set` assertion on a symbol kconfig had dropped entirely. The check
treats `# BR2_FOO is not set` as an assertion rather than a comment, which is
what made the third catch possible.

**A missing host tool surfaces only at the end.** `post-image.sh` needs
`mkimage`, and Buildroot selects `host-uboot-tools` automatically only for the
uImage kernel targets — which we deliberately do not use. Nothing warns; the
build runs to completion and then exits 127. Fixed by naming
`BR2_PACKAGE_HOST_UBOOT_TOOLS` explicitly, and `post-image.sh` now says so if
it ever happens again. Worth noting this was invisible until a *clean* build:
the incremental tree still had `mkimage` left over from the earlier
appended-uImage configuration.

**Rollback:** `git checkout main`, or `git checkout pre-buildroot` for the
exact known-good tree. Nothing on this branch touches the DVR.

## Questions answered at Stage 2

**Does Buildroot accept the Debian `gcc-arm-linux-gnueabihf`?** No, and not
for a fixable reason. See *The toolchain* under Decisions taken.

**Does `BR2_LINUX_KERNEL_APPENDED_UIMAGE` produce what the vendor U-Boot
expects?** Yes. Reading `linux/linux.mk:503-530`, it does exactly what
`build-in-container.sh` does by hand: `cat zImage <dtb> > zImage.<name>`, then
`mkimage -A arm -O linux -T kernel -C none`, reusing the load address, entry
point and image name read back from the kernel's own uImage. It also forces
`CONFIG_ARM_APPENDED_DTB` on. Set `BR2_LINUX_KERNEL_UIMAGE_LOADADDR` to
`0x80008000` and the result should match; the output is named
`uImage.hi3531-dhb-ax-ethernet` rather than the current filename.

**Is a post-image script needed?** Not for the image layout, on the above
reading. Confirm at Stage 3 by comparing against the `pre-buildroot` build —
this is a code reading, not yet a built artifact.

## Open questions

Both of Stage 3's questions are answered. `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR`
plus patch 0001 builds the DTBs correctly, and the `hisilicon/` prefix does
need handling — but in the uImage wrapping, not the DTB build, hence
`post-image.sh`. The gcc 14 toolchain proved to be a non-event: the kernel
boots and passes every check, with a byte-identical device tree.

- USB high speed and USB full speed remain unverified under Buildroot. They
  need a USB stick and an FTDI adapter plugged in; nothing was attached.
  These are the only two acceptance checks never exercised on this build.
- The Pi's SD card is full, which is now a working constraint rather than a
  footnote — picocom died mid-session when its logfile could not be written.
  See `../README.md`.
