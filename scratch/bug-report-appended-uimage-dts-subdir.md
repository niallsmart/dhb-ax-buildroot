# BR2_LINUX_KERNEL_APPENDED_UIMAGE fails when the DTS lives in a subdirectory

## Environment

- Buildroot `2026.02.3` (`buildroot/buildroot-2026.02.3` in this tree)
- `package/linux/linux.mk`
- Config: `BR2_LINUX_KERNEL_DTS_SUPPORT=y`, `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR` set
  to a directory containing the `.dts` one level down (e.g.
  `dts/hisilicon/foo.dts`), `BR2_LINUX_KERNEL_APPENDED_DTB=y`,
  `BR2_LINUX_KERNEL_APPENDED_UIMAGE=y`

## Summary

When a custom DTS is found by `find` under a subdirectory of
`BR2_LINUX_KERNEL_CUSTOM_DTS_DIR`, `LINUX_DTS_NAME` retains that subdirectory
component. Two consumers of `LINUX_DTS_NAME` in the appended-uImage path then
disagree about whether that component is part of the filename, and the build
fails when `mkimage` cannot find the intermediate file the previous step
produced.

## Root cause

`linux.mk` builds the DTS name list from a relative `find` listing:

```
LINUX_DTS_LIST := $(shell find $(LINUX_KERNEL_CUSTOM_DTS_DIR) -name '*.dts' -printf '%P\n' ...)
LINUX_DTS_NAME += $(basename $(LINUX_DTS_LIST))
```

`find -printf '%P'` prints the path relative to the search root, so a DTS in
a subdirectory keeps its subdirectory prefix (`hisilicon/foo.dts`). Make's
`$(basename ...)` only strips the file extension, not the directory, so
`LINUX_DTS_NAME` ends up as `hisilicon/foo` — subdirectory intact.

Two separate loops then consume that value differently when
`BR2_LINUX_KERNEL_APPENDED_UIMAGE=y`:

1. `LINUX_APPEND_DTB` (the `cat` step that appends the DTB to the zImage)
   correctly resolves the *input* DTB path using the full `${dtb}` (falling
   back to `dts/${dtb}.dtb`), but writes the *output* as
   `zImage.$$(basename ${dtb})`. The doubled `$$` means this is a **shell**
   `basename` call at build time, which strips the directory: the file is
   written as `zImage.foo` (flat, no `hisilicon/` prefix).

2. The `mkimage` loop that follows it re-iterates `$(LINUX_DTS_NAME)` and
   references `zImage.${dtb}` directly, with no basename step. Since `${dtb}`
   still equals `hisilicon/foo`, it looks for `zImage.hisilicon/foo` — a path
   with a literal `hisilicon/` component that does not exist, because step 1
   wrote a flat filename.

The two loops disagree on whether the subdirectory component belongs in the
filename: one strips it (via the shell), the other does not (make never
touches it). The `mkimage` step then fails to find the file the `cat` step
just produced.

Relevant lines (`buildroot/buildroot-2026.02.3/linux/linux.mk`):

- 216–219: `LINUX_DTS_LIST` / `LINUX_DTS_NAME` built from `find ... -printf '%P'`
- 505–514: `LINUX_APPEND_DTB`, writes `zImage.$$(basename $${dtb})`
- 516–530: `BR2_LINUX_KERNEL_APPENDED_UIMAGE` block, reads `zImage.${dtb}` with no basename

## Upstream status

Checked against `buildroot/buildroot` on GitHub (`main`, 2026-08-23): the two
loops still disagree the same way, at the same line numbers as
`2026.02.3` (505–514 and 516–530). This is not a long-standing bug; it
traces to a specific commit that fixed only one of the two loops.

Commit `8d2a51dc` ("linux: add support for vendor dirs for appended DTBs",
2023-07-07) added `$$(basename $${dtb})` to the `cat` line in
`LINUX_APPEND_DTB`, to fix:

```
cat zImage ${dtbpath} > zImage.${dtb} || exit 1
/bin/sh: line 1: zImage.cirrus/ep93xx-edb9302: No such file or directory
```

for the vendor-subdirectory DTS layout ARM Linux adopted in v6.4 (Linux
commit `724ba6751532`, "ARM: dts: Move .dts files to vendor
sub-directories"). The commit's diff touches only that one `cat` line; the
`mkimage` loop three lines below it, inside the
`BR2_LINUX_KERNEL_APPENDED_UIMAGE` block, was not updated to match. At the
time, this asymmetry only bit in-tree vendor DTS layouts.

Commit `290f6bb45a24` ("linux: introduce BR2_LINUX_KERNEL_CUSTOM_DTS_DIR",
2025-02-21) is what makes it reachable through the option this report uses.
It adds `LINUX_KERNEL_CUSTOM_DTS_DIR`, `LINUX_DTS_LIST` and the
`find ... -printf '%P'` logic at lines 212–219, so a *custom* DTS directory
can also populate `LINUX_DTS_NAME` with a subdirectory-prefixed entry
(`hisilicon/hi3531-dhb-ax`, in this tree's case). It reuses the existing
shared `LINUX_APPEND_DTB`/`mkimage` code from (1) as-is, so it inherits the
asymmetry without anyone touching the `mkimage` loop. The commit is
announced, with no discussion of this interaction, in the list's
[git-commit notification](https://lists.buildroot.org/pipermail/buildroot/2025-March/775153.html).

Anyone combining a subdirectory DTS layout — in-tree vendor dirs or
`BR2_LINUX_KERNEL_CUSTOM_DTS_DIR` — with `BR2_LINUX_KERNEL_APPENDED_UIMAGE`
hits this.

## Illustrating with `make printvars`

The mismatch is visible without a build, using Buildroot's `printvars`
target. This tree's own defconfig does not set
`BR2_LINUX_KERNEL_APPENDED_DTB`/`BR2_LINUX_KERNEL_APPENDED_UIMAGE` (it uses
the `post-image.sh` workaround instead), so the two variables are passed on
the `make` command line to exercise that code path for inspection, without
writing them into `.config`.

First, `LINUX_DTS_NAME` on its own, confirming the subdirectory prefix
survives into the name list for this board's DTS layout:

```
$ make printvars VARS=LINUX_DTS_NAME
LINUX_DTS_NAME=  hisilicon/hi3531-dhb-ax-minimal hisilicon/hi3531-dhb-ax
```

Then `LINUX_APPEND_DTB` itself, fully expanded, with the two options forced
on for this one invocation:

```
$ make printvars VARS=LINUX_APPEND_DTB \
    BR2_LINUX_KERNEL_APPENDED_DTB=y BR2_LINUX_KERNEL_APPENDED_UIMAGE=y
LINUX_APPEND_DTB=	(cd /output/build/linux-6.18.42/arch/arm/boot; for dtb in   hisilicon/hi3531-dhb-ax-minimal hisilicon/hi3531-dhb-ax; do if test -e ${dtb}.dtb ; then dtbpath=${dtb}.dtb ; else dtbpath=dts/${dtb}.dtb ; fi ; cat zImage ${dtbpath} > zImage.$(basename ${dtb}) || exit 1; done) ; MKIMAGE_ARGS=`/output/host/bin/mkimage -l /output/build/linux-6.18.42/arch/arm/boot/uImage | sed -n -e 's/Image Name:[ ]*\(.*\)/-n \1/p' -e 's/Load Address:/-a/p' -e 's/Entry Point:/-e/p'`; for dtb in   hisilicon/hi3531-dhb-ax-minimal hisilicon/hi3531-dhb-ax; do /output/host/bin/mkimage -A arm -O linux -T kernel -C none ${MKIMAGE_ARGS} -d /output/build/linux-6.18.42/arch/arm/boot/zImage.${dtb} /output/build/linux-6.18.42/arch/arm/boot/uImage.${dtb}; done
```

Reading the two `for dtb in ...` loops side by side, for
`dtb=hisilicon/hi3531-dhb-ax`: the first loop writes
`zImage.$(basename ${dtb})`, i.e. `zImage.hi3531-dhb-ax` (flat); the second
reads `-d .../boot/zImage.${dtb}`, i.e. `.../boot/zImage.hisilicon/hi3531-dhb-ax`
(subdirectory intact). The file the second loop looks for is not the file
the first loop wrote — with no build, no target board, and no DTB involved.

Adding `RAW_VARS=1` shows the same asymmetry at the source level, before
variable expansion, which is closer to how it reads in `linux.mk`:

```
$ make printvars VARS=LINUX_APPEND_DTB RAW_VARS=1 \
    BR2_LINUX_KERNEL_APPENDED_DTB=y BR2_LINUX_KERNEL_APPENDED_UIMAGE=y
LINUX_APPEND_DTB=	(cd $(LINUX_ARCH_PATH)/boot; for dtb in $(LINUX_DTS_NAME); do if test -e $${dtb}.dtb ; then dtbpath=$${dtb}.dtb ; else dtbpath=dts/$${dtb}.dtb ; fi ; cat zImage $${dtbpath} > zImage.$$(basename $${dtb}) || exit 1; done) ; MKIMAGE_ARGS=`$(MKIMAGE) -l $(LINUX_IMAGE_PATH) | sed -n -e 's/Image Name:[ ]*\(.*\)/-n \1/p' -e 's/Load Address:/-a/p' -e 's/Entry Point:/-e/p'`; for dtb in $(LINUX_DTS_NAME); do $(MKIMAGE) -A $(MKIMAGE_ARCH) -O linux -T kernel -C none $${MKIMAGE_ARGS} -d $(LINUX_ARCH_PATH)/boot/zImage.$${dtb} $(LINUX_IMAGE_PATH).$${dtb}; done
```

`$$(basename $${dtb})` in the `cat` line is a shell call (double `$`); the
bare `$${dtb}` in the `mkimage` line's `-d` argument is not.

## Reproduction

1. Configure a board with `BR2_LINUX_KERNEL_CUSTOM_DTS_DIR` pointing at a
   directory whose `.dts` files sit in a subdirectory (not directly in the
   configured directory).
2. Enable `BR2_LINUX_KERNEL_APPENDED_DTB=y` and
   `BR2_LINUX_KERNEL_APPENDED_UIMAGE=y`.
3. Build. The `mkimage` step fails because
   `$(LINUX_ARCH_PATH)/boot/zImage.<subdir>/<name>` does not exist.

## Workaround in this tree

Not used here: `board/dhb-ax/post-image.sh` does the DTB append and
`mkimage` wrap manually, with the same arguments the previous build used,
instead of relying on `BR2_LINUX_KERNEL_APPENDED_UIMAGE`. See the comment
in `br2-external/configs/dhb_ax_defconfig` above
`BR2_LINUX_KERNEL_ZIMAGE=y`.

## Suggested fix

Make the two loops agree — either both use `$(notdir ...)`/shell `basename`
consistently, or neither does, and the `mkimage` loop should locate the
appended file the same way `LINUX_APPEND_DTB` named it, e.g. by reusing
`$$(basename $${dtb})` in the second loop rather than the bare `${dtb}`.
