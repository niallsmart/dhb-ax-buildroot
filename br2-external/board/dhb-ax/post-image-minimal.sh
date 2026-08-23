#!/bin/sh
# Append the minimal DTB to the initramfs-bearing zImage and wrap it for the
# vendor U-Boot. The addresses and appended-DTB rationale are in post-image.sh.
set -eu

images=${1:-$BINARIES_DIR}
mkimage=${HOST_DIR:-/output/host}/bin/mkimage
version=$(sed -n \
	's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' \
	"$BR2_CONFIG")
stem=hi3531-dhb-ax-minimal
dtb=$images/$stem.dtb
appended=$images/zImage-$stem-appended-dtb
uimage=$images/uImage-$stem

test -f "$images/zImage"
test -f "$dtb"
test -n "$version"

if [ ! -x "$mkimage" ]; then
	echo "post-image-minimal: no mkimage at $mkimage" >&2
	echo "set BR2_PACKAGE_HOST_UBOOT_TOOLS=y" >&2
	exit 1
fi

cat "$images/zImage" "$dtb" > "$appended"

"$mkimage" -A arm -O linux -T kernel -C none \
	-a 0x80008000 -e 0x80008000 \
	-n "Linux-$version dhb-ax-minimal" \
	-d "$appended" \
	"$uimage" > /dev/null

echo "post-image-minimal: $(basename "$uimage")"
