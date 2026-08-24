#!/bin/sh
# Install a Buildroot filesystem on the prepared HDD and a uImage on USB.
#
# Full installation reformats the existing HDD partition but deliberately
# leaves both partition tables intact. The kernel-only modes update files on
# the USB boot filesystem without touching the HDD root filesystem.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
default_rootfs=$repo/artifacts/buildroot/rootfs.tar
default_uimage=$repo/artifacts/buildroot/uImage-hi3531-dhb-ax
default_minimal_uimage=$repo/artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal
. "$repo/scripts/lib.sh"
require_env_file "$repo/local.env" DHB_AX_DVR_IPADDR
target=root@${DHB_AX_DVR_IPADDR}

usage()
{
	cat <<EOF
usage: $0 [ROOTFS_TAR [UIMAGE]]
       $0 --kernel-only [UIMAGE]
       $0 --minimal [UIMAGE]

Full installation requires the DVR to be running from the minimal initramfs and
destructively recreates the ext4 filesystem on the prepared HDD partition.
The kernel-only form updates the USB uImage without touching the HDD.
The minimal form installs a diagnostic image alongside it as uImage-minimal.
EOF
}

mode=full
case ${1:-} in
	--kernel-only)
		mode=kernel
		shift
		[ "$#" -le 1 ] || { usage >&2; exit 2; }
		rootfs=-
		uimage=${1:-$default_uimage}
		;;
	--minimal)
		mode=minimal
		shift
		[ "$#" -le 1 ] || { usage >&2; exit 2; }
		rootfs=-
		uimage=${1:-$default_minimal_uimage}
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		[ "$#" -le 2 ] || { usage >&2; exit 2; }
		rootfs=${1:-$default_rootfs}
		uimage=${2:-$default_uimage}
		;;
esac

[ "$mode" != full ] ||
	[ -f "$rootfs" ] || { echo "no rootfs archive at $rootfs" >&2; exit 2; }
[ -f "$uimage" ] || { echo "no kernel image at $uimage" >&2; exit 2; }
remote_rootfs=/tmp/$(basename -- "$rootfs")
remote_uimage=/tmp/$(basename -- "$uimage")

if [ "$mode" = full ]; then
	ssh -o BatchMode=yes "$target" \
		"[ \"\$(hostname)\" = minimal ] && awk '\$2 == \"/\" && \$3 == \"rootfs\" { found = 1 } END { exit !found }' /proc/mounts" || {
		echo "dvr-install-system: the DVR is not the minimal initramfs; refusing to replace local storage" >&2
		exit 1
	}
	echo "Staging $(basename "$rootfs") and $(basename "$uimage") on $target..."
	scp -q -o BatchMode=yes -- "$rootfs" "$target:$remote_rootfs"
	scp -q -o BatchMode=yes -- "$uimage" "$target:$remote_uimage"
else
	echo "Staging $(basename "$uimage") on $target..."
	scp -q -o BatchMode=yes -- "$uimage" "$target:$remote_uimage"
fi

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

boot_part=$(blkid -t 'LABEL=DHBAXBOOT' -o device)
[ -b "$boot_part" ] || fail "USB boot partition not found"

grep -q "^$boot_part " /proc/mounts && fail "$boot_part is already mounted"
grep -q "^$boot_part " /proc/swaps 2>/dev/null &&
	fail "$boot_part is active swap"

if [ "$mode" = full ]; then
	root_part=$(blkid -t "PARTUUID=$root_partuuid" -o device)
	[ -b "$root_part" ] || fail "HDD root partition not found"

	grep -q "^$root_part " /proc/mounts && fail "$root_part is already mounted"
	grep -q "^$root_part " /proc/swaps 2>/dev/null &&
		fail "$root_part is active swap"

	echo "Formatting $root_part as the Buildroot root filesystem..."
	mke2fs -F -t ext4 -L dhb-ax-root -m 0 "$root_part"

	mkdir -p "$root_mount"
	mount -t ext4 "$root_part" "$root_mount"
	echo "Installing root filesystem on $root_part..."
	tar -xpf "$rootfs" -C "$root_mount"
	sync
	umount "$root_mount"
fi

mkdir -p "$boot_mount"
# The production kernel has vfat as a module; the minimal bootstrap has it
# built in. Mount remains the authoritative check in either case.
modprobe vfat 2>/dev/null || true
mount -t vfat "$boot_part" "$boot_mount"
if [ "$mode" = minimal ]; then
	kernel_name=uImage-minimal
else
	kernel_name=uImage
fi
rm -f "$boot_mount/$kernel_name.new"

echo "Installing kernel as $boot_part:/$kernel_name..."
cp "$uimage" "$boot_mount/$kernel_name.new"
sync
mv -f "$boot_mount/$kernel_name.new" "$boot_mount/$kernel_name"
rm -f "$boot_mount/$kernel_name.sha256"
sync

if [ "$mode" = full ]; then
	echo "Installed rootfs on $root_part (PARTUUID=$root_partuuid)"
fi
echo "Installed kernel on $boot_part as /$kernel_name"
REMOTE

if [ "$mode" = full ]; then
	echo "DVR HDD root and USB kernel installed successfully."
else
	echo "DVR USB kernel installed successfully."
fi
