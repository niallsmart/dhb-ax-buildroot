#!/bin/sh
# Keep tools that can destroy the DVR out of the image.
#
# The board's SPI NOR and NAND hold the only copy of the factory system, and
# the attached disk holds the owner's recordings.  The project rule is that
# nothing writes to either.  A rule is a thing you can forget at 2am; a binary
# that is not on the image is not.
#
# Kconfig gets most of this -- see the mtd and e2fsprogs sections of
# configs/dhb_ax_defconfig -- but not all of it.  mke2fs has no symbol of its
# own, so it arrives with the base e2fsprogs package no matter what.  This
# script removes what is left and then asserts the result, so the guarantee
# does not quietly lapse when a package is added or Buildroot is upgraded.
#
# $1 is TARGET_DIR.
set -eu

target=${1:-$TARGET_DIR}

# Anything here that survives to this point gets deleted.
writers="
mke2fs
mkfs.ext2
mkfs.ext3
mkfs.ext4
e2fsck
fsck.ext2
fsck.ext3
fsck.ext4
flash_erase
flash_eraseall
flashcp
nandwrite
mkfs.fat
mkfs.vfat
mkdosfs
ubiformat
"

removed=
for tool in $writers; do
	for dir in bin sbin usr/bin usr/sbin; do
		path=$target/$dir/$tool
		if [ -e "$path" ] || [ -L "$path" ]; then
			rm -f "$path"
			removed="$removed $dir/$tool"
		fi
	done
done

[ -n "$removed" ] && echo "post-build: removed writers:$removed"

# Assert, rather than trust the loop above.  A BusyBox applet symlink or a new
# package could reintroduce any of these.
still_there=
for tool in $writers; do
	for dir in bin sbin usr/bin usr/sbin; do
		[ -e "$target/$dir/$tool" ] && still_there="$still_there $dir/$tool"
	done
done

if [ -n "$still_there" ]; then
	echo "post-build: FAILED to remove:$still_there" >&2
	exit 1
fi

# The read-only tools this image exists to provide.  Losing one silently would
# be its own kind of surprise.  lighttpd is here on the dvr-extract branch: the
# image's reason to exist is serving the recordings, so a build that quietly
# dropped it should fail.
for tool in mtdinfo nanddump mtd_debug ethtool i2cdetect debugfs fsck.fat lighttpd; do
	found=
	for dir in bin sbin usr/bin usr/sbin; do
		[ -e "$target/$dir/$tool" ] && found=yes
	done
	if [ -z "$found" ]; then
		echo "post-build: expected tool missing: $tool" >&2
		exit 1
	fi
done

# mod_webdav is the one lighttpd module that can write into the served tree.
# The defconfig does not select it, so it should never be built -- assert that,
# because the read-only guarantee is only as good as its weakest surprise.
webdav=$(find "$target" -name 'mod_webdav.so' 2>/dev/null)
if [ -n "$webdav" ]; then
	echo "post-build: lighttpd mod_webdav present, must not be:$webdav" >&2
	exit 1
fi

echo "post-build: writers absent, read-only tools present, no mod_webdav"
