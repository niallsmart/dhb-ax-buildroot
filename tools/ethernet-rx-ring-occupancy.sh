#!/bin/sh
# Sample stmmac receive-descriptor ownership from debugfs without generating
# network traffic.  The output remains in the board's RAM filesystem so it can
# be collected over UART after a receive stall.
set -eu

seconds=${1:-}
descriptors=${2:-/sys/kernel/debug/stmmaceth/eth0/descriptors_status}

case $seconds in
	''|*[!0-9]*|0)
	echo "usage: $0 SECONDS [DESCRIPTORS_STATUS]" >&2
	exit 2
	;;
esac

test -r "$descriptors" || {
	echo "cannot read $descriptors" >&2
	exit 2
}

start=$(date +%s)
deadline=$((start + seconds))
samples=0
min_dma_owned=
max_cpu_owned=0

echo "uptime_s,dma_owned,cpu_owned,rx_state,csr5"
while [ "$(date +%s)" -lt "$deadline" ]; do
	set -- $(awk '
		/^RX Queue 0:/ { rx = 1; next }
		/^TX Queue 0:/ { exit }
		rx && $1 ~ /^[0-9]+$/ {
			nibble = tolower(substr($3, 3, 1))
			if (nibble ~ /[89abcdef]/)
				dma++
			else
				cpu++
		}
		END { print dma + 0, cpu + 0 }
	' "$descriptors")
	dma_owned=$1
	cpu_owned=$2
	csr5=$(devmem 0x101c1114 32)
	rx_state=$(( (csr5 & 0x000e0000) >> 17 ))
	uptime=$(cut -d' ' -f1 /proc/uptime)
	printf '%s,%s,%s,%s,%s\n' \
		"$uptime" "$dma_owned" "$cpu_owned" "$rx_state" "$csr5"
	if [ -z "$min_dma_owned" ] || [ "$dma_owned" -lt "$min_dma_owned" ]; then
		min_dma_owned=$dma_owned
	fi
	samples=$((samples + 1))
	[ "$cpu_owned" -gt "$max_cpu_owned" ] && max_cpu_owned=$cpu_owned
done

echo "# samples=$samples"
echo "# min_dma_owned=$min_dma_owned"
echo "# max_cpu_owned=$max_cpu_owned"
