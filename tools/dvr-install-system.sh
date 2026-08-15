#!/bin/sh
# Install a Buildroot filesystem on the prepared HDD and a uImage on USB.
#
# This is deliberately separate from dvr-prepare-storage.sh: rebuilding and
# reinstalling the system must not recreate either partition table.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-$repo/artifacts/buildroot/rootfs.tar}
uimage=${2:-$repo/artifacts/buildroot/uImage-hi3531-dhb-ax-full}
target=${DVR_SSH:-root@192.168.4.77}
remote_rootfs=/tmp/dhb-ax-install-rootfs.tar
remote_uimage=/tmp/dhb-ax-install-uImage

[ -f "$rootfs" ] || { echo "no rootfs archive at $rootfs" >&2; exit 2; }
[ -f "$uimage" ] || { echo "no kernel image at $uimage" >&2; exit 2; }

echo "Staging $(basename "$rootfs") and $(basename "$uimage") on $target..."
scp -q -o BatchMode=yes -- "$rootfs" "$target:$remote_rootfs"
scp -q -o BatchMode=yes -- "$uimage" "$target:$remote_uimage"

ssh -o BatchMode=yes "$target" sh -s -- "$remote_rootfs" "$remote_uimage" <<'REMOTE'
set -eu

rootfs=$1
uimage=$2
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
	rm -f "$rootfs" "$uimage"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

grep -q ' / nfs ' /proc/mounts ||
	fail "the DVR root is not NFS; refusing to replace the running local system"
[ -f "$rootfs" ] || fail "staged rootfs archive is missing"
[ -f "$uimage" ] || fail "staged uImage is missing"

root_part=$(blkid -t "PARTUUID=$root_partuuid" -o device)
boot_part=$(blkid -t 'LABEL=DHBAXBOOT' -o device)
[ -b "$root_part" ] || fail "HDD root partition not found"
[ -b "$boot_part" ] || fail "USB boot partition not found"

[ "$(blkid -s TYPE -o value "$root_part")" = ext4 ] ||
	fail "$root_part is not ext4"
[ "$(blkid -s TYPE -o value "$boot_part")" = vfat ] ||
	fail "$boot_part is not FAT"

root_disk=${root_part%1}
boot_disk=${boot_part%1}
root_name=${root_disk##*/}
boot_name=${boot_disk##*/}
[ "$(cat /sys/class/block/$root_name/size)" = 1953525168 ] ||
	fail "unexpected HDD size"
[ "$(cat /sys/class/block/$root_name/removable)" = 0 ] ||
	fail "HDD unexpectedly reports removable"
[ "$(tr -d ' ' < /sys/class/block/$root_name/device/model)" = WDCWD10EURX-63C ] ||
	fail "unexpected HDD model"
[ "$(cat /sys/class/block/$boot_name/size)" = 15728640 ] ||
	fail "unexpected USB size"
[ "$(cat /sys/class/block/$boot_name/removable)" = 1 ] ||
	fail "USB unexpectedly reports non-removable"
[ "$(tr -d ' ' < /sys/class/block/$boot_name/device/model)" = FlashVoyager ] ||
	fail "unexpected USB model"

for part in "$root_part" "$boot_part"; do
	grep -q "^$part " /proc/mounts && fail "$part is already mounted"
done

mkdir -p "$root_mount" "$boot_mount"
mount -t ext4 "$root_part" "$root_mount"
if find "$root_mount" -mindepth 1 -maxdepth 1 ! -name lost+found -print |
	grep -q .; then
	fail "$root_part is not an empty prepared filesystem"
fi

modprobe vfat
mount -t vfat "$boot_part" "$boot_mount"
if find "$boot_mount" -mindepth 1 -maxdepth 1 -print | grep -q .; then
	fail "$boot_part is not an empty prepared filesystem"
fi

echo "Installing root filesystem on $root_part..."
tar -xpf "$rootfs" -C "$root_mount"

echo "Installing kernel as $boot_part:/uImage..."
cp "$uimage" "$boot_mount/uImage"
(cd "$boot_mount" && sha256sum uImage > uImage.sha256)
sync

[ -x "$root_mount/sbin/init" ] || fail "installed root has no /sbin/init"
[ -x "$root_mount/usr/sbin/sshd" ] || fail "installed root has no sshd"
[ -s "$boot_mount/uImage" ] || fail "installed uImage is empty"

echo "Installed rootfs on $root_part (PARTUUID=$root_partuuid)"
echo "Installed kernel on $boot_part as /uImage"
REMOTE

echo "DVR HDD root and USB kernel installed successfully."
