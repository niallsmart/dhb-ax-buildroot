#!/bin/sh
# Destructively prepare the known DHB_AX HDD and USB flash drive for Linux.
#
# Run this from the development host while the DVR is using the minimal
# initramfs. The strict hardware checks are intentional: /dev/sdX names alone
# are not enough justification for erasing a disk.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
require_env_file "$repo/local.env" DHB_AX_DVR_IPADDR
target=root@${DHB_AX_DVR_IPADDR}

if [ "${1:-}" != "--destroy-all-data" ] || [ "$#" -ne 1 ]; then
	echo "usage: $0 --destroy-all-data" >&2
	echo "" >&2
	echo "This erases the 250 GB Samsung SSD and 8 GB Corsair USB drive." >&2
	exit 2
fi

ssh -o BatchMode=yes "$target" sh -s <<'REMOTE'
set -eu

fail()
{
	echo "dvr-prepare-storage: $*" >&2
	exit 1
}

find_device()
{
	want_size=$1
	want_removable=$2
	want_path=$3
	want_model=$4
	found=

	for sysdev in /sys/class/block/sd?; do
		[ -e "$sysdev" ] || continue
		[ "$(cat "$sysdev/size")" = "$want_size" ] || continue
		[ "$(cat "$sysdev/removable")" = "$want_removable" ] || continue
		path=$(readlink -f "$sysdev")
		case $path in
			*$want_path*) ;;
			*) continue ;;
		esac
		model=$(tr -d ' ' < "$sysdev/device/model")
		[ "$model" = "$want_model" ] || continue
		[ -z "$found" ] || fail "more than one device matches $want_model"
		found=/dev/${sysdev##*/}
	done

	[ -n "$found" ] || fail "could not identify $want_model"
	echo "$found"
}

# These identifiers come from the actual devices fitted to this DVR. The
# topology check distinguishes the SATA disk from removable USB storage even
# if Linux assigns their sdX names in a different order. The model is compared
# with its spaces removed, as sysfs pads the field.
hdd=$(find_device 488397168 0 /10080000.sata/ SamsungSSD860)
usb=$(find_device 15728640 1 /100b0000.usb/ FlashVoyager)
[ "$hdd" != "$usb" ] || fail "HDD and USB resolved to the same device"

[ "$(hostname)" = minimal ] ||
	fail "the DVR is not the minimal bootstrap image; refusing to alter local storage"
awk '$2 == "/" && $3 == "rootfs" { found = 1 }
	END { exit !found }' /proc/mounts ||
	fail "the DVR root is not the minimal initramfs; refusing to alter local storage"

for dev in "$hdd" "$usb"; do
	if grep -q "^$dev" /proc/mounts; then
		fail "$dev or one of its partitions is mounted"
	fi
	if grep -q "^$dev" /proc/swaps 2>/dev/null; then
		fail "$dev or one of its partitions is active swap"
	fi
done

echo "HDD: $hdd ($(cat /sys/class/block/${hdd##*/}/device/model), $(cat /sys/class/block/${hdd##*/}/size) sectors)"
echo "USB: $usb ($(cat /sys/class/block/${usb##*/}/device/model), $(cat /sys/class/block/${usb##*/}/size) sectors)"
echo "Erasing both partition tables and all filesystem signatures..."

sfdisk --lock=yes --wipe=always --wipe-partitions=always "$hdd" <<'HDD_TABLE'
label: gpt
unit: sectors

start=2048, size=67108864, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="dhb-ax-buildroot", uuid=ca264b64-5738-4e60-a0ab-b3c3a4c789c1
start=67110912, size=134217728, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="dhb-ax-debian", uuid=8EBB5255-A43A-4B4E-953D-E81D2E0A2A6F
start=201328640, size=8388608, type=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F, name="dhb-ax-swap", uuid=D8E11399-926E-4805-BC25-641EB3BE6C54
start=209717248, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="dhb-ax-data", uuid=FCB65DE3-F88D-4F21-BAB7-C85F5587C9E2
HDD_TABLE

sfdisk --lock=yes --wipe=always --wipe-partitions=always "$usb" <<'USB_TABLE'
label: dos
unit: sectors

start=2048, type=c, bootable
USB_TABLE

mdev -s
hdd_buildroot=${hdd}1
hdd_debian=${hdd}2
hdd_swap=${hdd}3
hdd_data=${hdd}4
usb_part=${usb}1
for part in "$hdd_buildroot" "$hdd_debian" "$hdd_swap" "$hdd_data" "$usb_part"; do
	i=0
	while [ ! -b "$part" ] && [ "$i" -lt 20 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -b "$part" ] || fail "partition device did not appear: $part"
done

mke2fs -t ext4 -L dhb-ax-buildroot -m 0 "$hdd_buildroot"
mke2fs -t ext4 -L dhb-ax-debian -m 0 "$hdd_debian"
mkswap -L dhb-ax-swap "$hdd_swap"
mke2fs -t ext4 -L dhb-ax-data -m 0 "$hdd_data"
mkfs.fat -F 32 -n DHBAXBOOT "$usb_part"
sync

echo "Prepared HDD roots, swap, and shared data:"
blkid "$hdd_buildroot" "$hdd_debian" "$hdd_swap" "$hdd_data"
echo "Prepared USB boot filesystem: $usb_part"
blkid "$usb_part"
REMOTE
