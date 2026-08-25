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

for tool in \
	sfdisk mke2fs mkfs.fat mkswap blkid tar \
	getfacl setfacl getfattr setfattr; do
	if ! find_tool "$tool"; then
		echo "post-build-minimal: expected tool missing: $tool" >&2
		exit 1
	fi
done

for tar_path in "$target/bin/tar" "$target/usr/bin/tar"; do
	[ -e "$tar_path" ] || continue
	case $(readlink "$tar_path" 2>/dev/null || :) in
	*busybox*)
		echo 'post-build-minimal: GNU tar was replaced by the BusyBox applet' >&2
		exit 1
		;;
	esac
done

# Neither the package set nor the minimal DTB needs access to factory flash.
for tool in flash_erase flash_eraseall flashcp nandwrite ubiformat; do
	if find_tool "$tool"; then
		echo "post-build-minimal: forbidden flash writer present: $tool" >&2
		exit 1
	fi
done

echo "post-build-minimal: metadata-safe storage tools present, flash writers absent"
