#!/bin/sh
# Read-only sequential read benchmark for external USB storage on macOS.
#
#   sudo tools/benchmark-usb.sh            # all external physical disks
#   sudo tools/benchmark-usb.sh 4 6        # only /dev/rdisk4 and /dev/rdisk6
#
# Root is required because raw block devices are not readable otherwise.
#
# This script only ever reads. It opens each device read-only, copies to
# /dev/null, and mounts nothing. It does not write to any device, and it will
# refuse to run against a disk that has a mounted volume so that a benchmark
# can never contend with live filesystem I/O.
set -eu

SIZE_MB=${SIZE_MB:-256}     # how much to read per device
SKIP_MB=${SKIP_MB:-1024}    # where to start; see note below

if [ "$(id -u)" -ne 0 ]; then
	echo "error: raw device reads need root; re-run with sudo" >&2
	exit 1
fi

case "$(uname)" in
Darwin) ;;
*) echo "error: this script is macOS-specific (diskutil, /dev/rdisk)" >&2; exit 1 ;;
esac

# Which disks to test.
if [ $# -gt 0 ]; then
	disks=$*
else
	disks=$(diskutil list external physical 2>/dev/null \
		| sed -n 's|^/dev/disk\([0-9][0-9]*\) .*|\1|p')
fi

if [ -z "$disks" ]; then
	echo "no external physical disks found" >&2
	exit 1
fi

printf '%-18s %10s %12s %10s\n' DEVICE SIZE READ NAME
printf '%s\n' "----------------------------------------------------------------"

for d in $disks; do
	dev=/dev/rdisk$d
	[ -e "$dev" ] || { echo "skip disk$d: no such device" >&2; continue; }

	name=$(diskutil info "disk$d" 2>/dev/null \
		| sed -n 's/.*Device \/ Media Name: *//p')
	size=$(diskutil info "disk$d" 2>/dev/null \
		| sed -n 's/.*Disk Size: *//p' | sed 's/ (.*//')

	# Refuse to benchmark a disk with anything mounted: the numbers would be
	# contaminated by other I/O, and reading a device in use is impolite.
	if mount | grep -q "^/dev/disk${d}s"; then
		printf '%-18s %10s %12s %s\n' "disk$d" "$size" "SKIPPED" \
			"(has a mounted volume — unmount first)"
		continue
	fi

	# Raw device (/dev/rdisk, not /dev/disk) bypasses the buffer cache, so
	# this measures the device rather than RAM. Starting SKIP_MB in avoids
	# partition tables and filesystem metadata; flash media is often slower
	# at the very start of the device, which would flatter nothing.
	out=$(dd if="$dev" of=/dev/null bs=1m count="$SIZE_MB" iseek="$SKIP_MB" 2>&1 || true)

	rate=$(printf '%s\n' "$out" | sed -n 's/.*(\(.*\) bytes\/sec.*/\1/p')
	if [ -n "$rate" ]; then
		mbs=$(awk -v r="$rate" 'BEGIN{printf "%.1f MB/s", r/1000000}')
	else
		# dd failed: too small to seek into, device unreadable, etc.
		mbs=$(printf '%s\n' "$out" | sed -n '1s/.*: //p')
		[ -n "$mbs" ] || mbs="failed"
	fi

	printf '%-18s %10s %12s %s\n' "disk$d" "$size" "$mbs" "$name"
done

printf '\n%s\n' "Read ${SIZE_MB} MiB from ${SKIP_MB} MiB in, via the raw device (cache bypassed)."
printf '%s\n' "Override with: SIZE_MB=512 SKIP_MB=2048 sudo tools/benchmark-usb.sh"
