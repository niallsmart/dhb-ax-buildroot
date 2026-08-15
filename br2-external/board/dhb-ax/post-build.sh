#!/bin/sh
# Keep tools that can destroy the DVR's factory flash out of the image.
#
# The board's SPI NOR and NAND hold the only copy of the factory system, and
# remain strictly read-only. The HDD and USB flash drive are now approved
# Linux storage, so their partitioning and filesystem tools remain available.
# A rule is a thing you can forget at 2am; a flash-writing binary that is not
# on the image is not.
#
# Kconfig gets most of this -- see the mtd section of
# configs/dhb_ax_defconfig -- but removing the remaining tools here prevents
# package defaults or a Buildroot upgrade from reintroducing a flash writer.
#
# $1 is TARGET_DIR.
set -eu

target=${1:-$TARGET_DIR}
local_ssh=${2:-}

# SSH credentials are deliberately machine-local. The host private keys must
# survive rebuilds so clients see a stable identity, but they must never enter
# source control. Supplying every key type expected by ssh-keygen -A also keeps
# the standard Buildroot sshd init script from generating keys at boot. The
# authorized key is copied beside them under the same explicit build contract.
if [ -z "$local_ssh" ]; then
	echo "post-build: local SSH input directory argument is missing" >&2
	exit 1
fi
host_keys="
ssh_host_rsa_key
ssh_host_ecdsa_key
ssh_host_ed25519_key
"
for file in $host_keys authorized_keys; do
	if [ ! -f "$local_ssh/$file" ]; then
		echo "post-build: missing local SSH input: $local_ssh/$file" >&2
		exit 1
	fi
done

install -d -m 0700 "$target/root/.ssh"
install -m 0600 "$local_ssh/authorized_keys" \
	"$target/root/.ssh/authorized_keys"
install -d -m 0755 "$target/etc/ssh"
for file in $host_keys; do
	install -m 0600 "$local_ssh/$file" "$target/etc/ssh/$file"
done

# Anything here that survives to this point gets deleted.
writers="
flash_erase
flash_eraseall
flashcp
nandwrite
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

# Assert the inspection and approved-storage provisioning tools the image is
# expected to provide. Losing one silently would be its own kind of surprise.
required_tools="
mtdinfo
nanddump
mtd_debug
ethtool
i2cdetect
debugfs
fsck.fat
sfdisk
blkid
mke2fs
e2fsck
mkfs.fat
"
for tool in $required_tools; do
	found=
	for dir in bin sbin usr/bin usr/sbin; do
		[ -e "$target/$dir/$tool" ] && found=yes
	done
	if [ -z "$found" ]; then
		echo "post-build: expected tool missing: $tool" >&2
		exit 1
	fi
done

echo "post-build: flash writers absent, storage tools present"
echo "post-build: installed durable OpenSSH host and root authorized keys"
