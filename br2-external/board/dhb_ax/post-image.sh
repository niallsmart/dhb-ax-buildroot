#!/bin/sh
# Wrap the kernel for the vendor U-Boot: append the DTB to the zImage, then
# put a legacy uImage header on the result.
#
# Buildroot has BR2_LINUX_KERNEL_APPENDED_UIMAGE, which does exactly this, and
# it cannot be used here.  Its LINUX_APPEND_DTB runs two loops over
# LINUX_DTS_NAME: the `cat` loop takes $(basename ${dtb}), the mkimage loop
# does not.  Our device trees live in a hisilicon/ subdirectory -- they have to,
# because patch 0001 adds them to arch/arm/boot/dts/hisilicon/Makefile -- so
# LINUX_DTS_NAME carries that prefix and mkimage is asked to write
# "uImage.hisilicon/hi3531-dhb-ax", a path whose directory does not exist:
#
#   mkimage: Can't open .../arch/arm/boot/uImage.hisilicon/hi3531-dhb-ax:
#            No such file or directory
#
# So the kernel is built as a plain zImage and wrapped here instead.  The
# arguments below match what the retired pre-Buildroot build used.
#
# $1 is BINARIES_DIR, which already holds zImage and the built DTBs.
set -eu

images=${1:-$BINARIES_DIR}
mkimage=${HOST_DIR:-/output/host}/bin/mkimage

test -f "$images/zImage"

if [ ! -x "$mkimage" ]; then
	echo "post-image: no mkimage at $mkimage" >&2
	echo "set BR2_PACKAGE_HOST_UBOOT_TOOLS=y -- Buildroot only pulls it in" >&2
	echo "automatically for the uImage kernel targets, which we do not use" >&2
	exit 1
fi

for stem in hi3531-dhb-ax hi3531-dhb-ax-full; do
	dtb=$images/$stem.dtb
	test -f "$dtb"
	appended=$images/zImage-$stem-appended-dtb
	uimage=$images/uImage-$stem

	cat "$images/zImage" "$dtb" > "$appended"

	# Load and entry address both 0x80008000: this U-Boot passes ATAGs and
	# has no FDT commands, so the kernel must land where it expects.
	"$mkimage" -A arm -O linux -T kernel -C none \
		-a 0x80008000 -e 0x80008000 \
		-n "Linux-6.18.42 $stem" \
		-d "$appended" \
		"$uimage" > /dev/null

	echo "post-image: $(basename "$uimage")"
done
