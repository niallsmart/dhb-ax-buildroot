#!/bin/sh
# Destructively prepare the known DHB_AX HDD and USB flash drive for Linux.
#
# Run this from the development host while the DVR is using its NFS root. The
# strict hardware checks are intentional: /dev/sdX names alone are not enough
# justification for erasing a disk.
set -eu

target=${DVR_SSH:-root@192.168.4.77}

if [ "${1:-}" != "--destroy-all-data" ] || [ "$#" -ne 1 ]; then
	echo "usage: $0 --destroy-all-data" >&2
	echo "" >&2
	echo "This erases the 1 TB WDC HDD and 8 GB Corsair USB drive." >&2
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
# if Linux assigns their sdX names in a different order.
hdd=$(find_device 1953525168 0 /10080000.sata/ WDCWD10EURX-63C)
usb=$(find_device 15728640 1 /100b0000.usb/ FlashVoyager)
[ "$hdd" != "$usb" ] || fail "HDD and USB resolved to the same device"

grep -q ' / nfs ' /proc/mounts ||
	fail "the DVR root is not NFS; refusing to alter local storage"

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

start=2048, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="dhb-ax-root", uuid=ca264b64-5738-4e60-a0ab-b3c3a4c789c1
HDD_TABLE

sfdisk --lock=yes --wipe=always --wipe-partitions=always "$usb" <<'USB_TABLE'
label: dos
unit: sectors

start=2048, type=c, bootable
USB_TABLE

mdev -s
hdd_part=${hdd}1
usb_part=${usb}1
for part in "$hdd_part" "$usb_part"; do
	i=0
	while [ ! -b "$part" ] && [ "$i" -lt 20 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -b "$part" ] || fail "partition device did not appear: $part"
done

mke2fs -t ext4 -L dhb-ax-root -m 0 "$hdd_part"
mkfs.fat -F 32 -n DHBAXBOOT "$usb_part"
sync

hdd_partuuid=$(blkid -s PARTUUID -o value "$hdd_part")
[ "$hdd_partuuid" = ca264b64-5738-4e60-a0ab-b3c3a4c789c1 ] ||
	fail "unexpected HDD PARTUUID: $hdd_partuuid"

echo "Prepared HDD root: $hdd_part"
echo "  PARTUUID=$hdd_partuuid"
echo "Prepared USB boot filesystem: $usb_part"
blkid "$hdd_part" "$usb_part"
REMOTE
