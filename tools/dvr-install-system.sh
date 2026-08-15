#!/bin/sh
# Install a Buildroot filesystem on the prepared HDD and a uImage on USB.
#
# Full installation reformats the existing HDD partition but deliberately
# leaves both partition tables intact. Use --kernel-only for normal kernel
# iteration without touching the HDD root filesystem.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
default_rootfs=$repo/artifacts/buildroot/rootfs.tar
default_uimage=$repo/artifacts/buildroot/uImage-hi3531-dhb-ax-full
target=${DVR_SSH:-root@dvr}
remote_rootfs=/tmp/dhb-ax-install-rootfs.tar
remote_uimage=/tmp/dhb-ax-install-uImage

usage()
{
	cat >&2 <<EOF
usage: $0 [ROOTFS_TAR [UIMAGE]]
       $0 --kernel-only [UIMAGE]

Full installation requires the DVR to be running from its NFS root and
destructively recreates the ext4 filesystem on the prepared HDD partition.
The kernel-only form updates the USB uImage without touching the HDD.
EOF
}

mode=full
case ${1:-} in
	--kernel-only)
		mode=kernel
		shift
		[ "$#" -le 1 ] || { usage; exit 2; }
		rootfs=-
		uimage=${1:-$default_uimage}
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		[ "$#" -le 2 ] || { usage; exit 2; }
		rootfs=${1:-$default_rootfs}
		uimage=${2:-$default_uimage}
		;;
esac

[ "$mode" = kernel ] ||
	[ -f "$rootfs" ] || { echo "no rootfs archive at $rootfs" >&2; exit 2; }
[ -f "$uimage" ] || { echo "no kernel image at $uimage" >&2; exit 2; }

if [ "$mode" = full ]; then
	ssh -o BatchMode=yes "$target" \
		"awk '\$2 == \"/\" && (\$3 == \"nfs\" || \$3 == \"nfs4\") { found = 1 } END { exit !found }' /proc/mounts" || {
		echo "dvr-install-system: the DVR root is not NFS; refusing to replace the running local system" >&2
		exit 1
	}
	echo "Staging $(basename "$rootfs") and $(basename "$uimage") on $target..."
	scp -q -o BatchMode=yes -- "$rootfs" "$target:$remote_rootfs"
else
	echo "Staging $(basename "$uimage") on $target..."
fi
scp -q -o BatchMode=yes -- "$uimage" "$target:$remote_uimage"

ssh -o BatchMode=yes "$target" sh -s -- \
	"$mode" "$remote_rootfs" "$remote_uimage" <<'REMOTE'
set -eu

mode=$1
rootfs=$2
uimage=$3
root_mount=/mnt/dhb-ax-root
boot_mount=/mnt/dhb-ax-boot
root_partuuid=ca264b64-5738-4e60-a0ab-b3c3a4c789c1

fail()
{
	echo "dvr-install-system: $*" >&2
	exit 1
}

cleanup()
{
	sync
	grep -q " $boot_mount " /proc/mounts && umount "$boot_mount" || true
	grep -q " $root_mount " /proc/mounts && umount "$root_mount" || true
	[ "$rootfs" = - ] || rm -f "$rootfs"
	rm -f "$uimage"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ "$mode" = full ] || [ "$mode" = kernel ] || fail "invalid installation mode"
[ -f "$uimage" ] || fail "staged uImage is missing"
if [ "$mode" = full ]; then
	awk '$2 == "/" && ($3 == "nfs" || $3 == "nfs4") { found = 1 }
		END { exit !found }' /proc/mounts ||
		fail "the DVR root is not NFS; refusing to replace the running local system"
	[ -f "$rootfs" ] || fail "staged rootfs archive is missing"
fi

boot_part=$(blkid -t 'LABEL=DHBAXBOOT' -o device)
[ -b "$boot_part" ] || fail "USB boot partition not found"
[ "$(blkid -s TYPE -o value "$boot_part")" = vfat ] ||
	fail "$boot_part is not FAT"

boot_disk=${boot_part%1}
boot_name=${boot_disk##*/}
[ "$(cat /sys/class/block/$boot_name/size)" = 15728640 ] ||
	fail "unexpected USB size"
[ "$(cat /sys/class/block/$boot_name/removable)" = 1 ] ||
	fail "USB unexpectedly reports non-removable"
[ "$(tr -d ' ' < /sys/class/block/$boot_name/device/model)" = FlashVoyager ] ||
	fail "unexpected USB model"

grep -q "^$boot_part " /proc/mounts && fail "$boot_part is already mounted"
grep -q "^$boot_part " /proc/swaps 2>/dev/null &&
	fail "$boot_part is active swap"

if [ "$mode" = full ]; then
	root_part=$(blkid -t "PARTUUID=$root_partuuid" -o device)
	[ -b "$root_part" ] || fail "HDD root partition not found"

	root_disk=${root_part%1}
	root_name=${root_disk##*/}
	[ "$(cat /sys/class/block/$root_name/size)" = 1953525168 ] ||
		fail "unexpected HDD size"
	[ "$(cat /sys/class/block/$root_name/removable)" = 0 ] ||
		fail "HDD unexpectedly reports removable"
	[ "$(tr -d ' ' < /sys/class/block/$root_name/device/model)" = WDCWD10EURX-63C ] ||
		fail "unexpected HDD model"

	grep -q "^$root_part " /proc/mounts && fail "$root_part is already mounted"
	grep -q "^$root_part " /proc/swaps 2>/dev/null &&
		fail "$root_part is active swap"

	echo "Formatting $root_part as the Buildroot root filesystem..."
	mke2fs -F -t ext4 -L dhb-ax-root -m 0 "$root_part"
	[ "$(blkid -s TYPE -o value "$root_part")" = ext4 ] ||
		fail "new root filesystem is not ext4"
	[ "$(blkid -s LABEL -o value "$root_part")" = dhb-ax-root ] ||
		fail "new root filesystem has the wrong label"

	mkdir -p "$root_mount"
	mount -t ext4 "$root_part" "$root_mount"
	echo "Installing root filesystem on $root_part..."
	tar -xpf "$rootfs" -C "$root_mount"

	[ -x "$root_mount/sbin/init" ] || fail "installed root has no /sbin/init"
	[ -x "$root_mount/usr/sbin/sshd" ] || fail "installed root has no sshd"
	sync
	umount "$root_mount"
fi

mkdir -p "$boot_mount"
modprobe vfat
mount -t vfat "$boot_part" "$boot_mount"
rm -f "$boot_mount/uImage.new" "$boot_mount/uImage.sha256.new"

echo "Installing kernel as $boot_part:/uImage..."
cp "$uimage" "$boot_mount/uImage.new"
source_sum=$(sha256sum "$uimage" | awk '{ print $1 }')
installed_sum=$(sha256sum "$boot_mount/uImage.new" | awk '{ print $1 }')
[ "$installed_sum" = "$source_sum" ] || fail "installed uImage checksum mismatch"
printf '%s  uImage\n' "$installed_sum" > "$boot_mount/uImage.sha256.new"
sync
mv -f "$boot_mount/uImage.new" "$boot_mount/uImage"
mv -f "$boot_mount/uImage.sha256.new" "$boot_mount/uImage.sha256"
sync

[ -s "$boot_mount/uImage" ] || fail "installed uImage is empty"
[ "$(sha256sum "$boot_mount/uImage" | awk '{ print $1 }')" = "$source_sum" ] ||
	fail "final uImage checksum mismatch"

if [ "$mode" = full ]; then
	echo "Installed rootfs on $root_part (PARTUUID=$root_partuuid)"
fi
echo "Installed kernel on $boot_part as /uImage"
REMOTE

if [ "$mode" = full ]; then
	echo "DVR HDD root and USB kernel installed successfully."
else
	echo "DVR USB kernel installed successfully."
fi
