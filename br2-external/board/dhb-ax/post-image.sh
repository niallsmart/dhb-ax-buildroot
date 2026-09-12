#!/bin/sh
# Wrap the kernel for the vendor U-Boot: append the DTB to the zImage, then
# put a legacy uImage header on the result.
#
# Buildroot has BR2_LINUX_KERNEL_APPENDED_UIMAGE, which does exactly this, and
# it cannot be used here.  Its LINUX_APPEND_DTB runs two loops over
# LINUX_DTS_NAME: the `cat` loop takes $(basename ${dtb}), the mkimage loop
# does not.  Our device trees live in a hisilicon/ subdirectory -- they have to,
# because patch 0001 adds it to arch/arm/boot/dts/hisilicon/Makefile -- so
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
mkimage=${HOST_DIR:-${HOME}/output/host}/bin/mkimage
version=$(sed -n \
	's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' \
	"$BR2_CONFIG")

test -f "$images/zImage"
test -n "$version"

if [ ! -x "$mkimage" ]; then
	echo "post-image: no mkimage at $mkimage" >&2
	echo "set BR2_PACKAGE_HOST_UBOOT_TOOLS=y -- Buildroot only pulls it in" >&2
	echo "automatically for the uImage kernel targets, which we do not use" >&2
	exit 1
fi

stem=hi3531-dhb-ax
dtb=$images/$stem.dtb
test -f "$dtb"
appended=$images/zImage-$stem-appended-dtb
uimage=$images/uImage-$stem

cat "$images/zImage" "$dtb" > "$appended"

# The vendor U-Boot refuses a kernel payload whose destination range reaches
# 0x80800000 ("kernel image will overwrite uboot"). The payload starts at
# 0x80008000, leaving 0x7f8000 bytes for the appended zImage and DTB.
max_payload=8355840
min_margin=524288
max_planned_payload=$((max_payload - min_margin))
payload_size=$(wc -c < "$appended")
if [ "$payload_size" -gt "$max_planned_payload" ]; then
	echo "post-image: payload is $payload_size bytes; at least $min_margin bytes must remain below the $max_payload-byte vendor U-Boot ceiling" >&2
	exit 1
fi

# Load and entry address both 0x80008000: this U-Boot passes ATAGs and
# has no FDT commands, so the kernel must land where it expects.
"$mkimage" -A arm -O linux -T kernel -C none \
	-a 0x80008000 -e 0x80008000 \
	-n "Linux-$version $stem" \
	-d "$appended" \
	"$uimage" > /dev/null

margin=$((max_payload - payload_size))
echo "post-image: $(basename "$uimage") ($margin-byte payload margin)"

set -- "$TARGET_DIR"/lib/modules/*
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
	echo "post-image: rootfs must contain exactly one kernel module release" >&2
	exit 1
fi
release=${1##*/}
if [ "$release" != "$version" ]; then
	echo "post-image: module release $release does not match configured kernel $version" >&2
	exit 1
fi

# The target tree belongs to the unprivileged build user. Record the ownership
# the modules will have in the final target filesystem.
tar --sort=name --numeric-owner --owner=0 --group=0 -C "$TARGET_DIR" \
	-cf "$images/kernel-modules.tar" lib/modules
echo "post-image: kernel modules $release -> kernel-modules.tar"
