#!/bin/sh
# Install SSH material and audit the initramfs storage-bootstrap toolset.
set -eu

target=${1:-$TARGET_DIR}
local_ssh=${2:-}
board_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$board_dir/post-build-ssh.sh" "$target" "$local_ssh"

find_tool()
{
	for dir in bin sbin usr/bin usr/sbin; do
		[ -e "$target/$dir/$1" ] && return 0
	done
	return 1
}

# cpio and gunzip unpack the root filesystem archive that dvr-stage streams
# onto the HDD partition; the rest partition and format the approved devices.
for tool in \
	sfdisk mke2fs mkfs.fat mkswap blkid cpio gunzip; do
	if ! find_tool "$tool"; then
		echo "post-build-minimal: expected tool missing: $tool" >&2
		exit 1
	fi
done

# Neither the package set nor the minimal DTB needs access to factory flash.
for tool in flash_erase flash_eraseall flashcp nandwrite ubiformat; do
	if find_tool "$tool"; then
		echo "post-build-minimal: forbidden flash writer present: $tool" >&2
		exit 1
	fi
done

echo "post-build-minimal: storage bootstrap tools present, flash writers absent"
