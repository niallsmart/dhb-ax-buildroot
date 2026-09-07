#!/bin/sh
# Reproduce the Hi3531 receive wedge: inbound traffic, then repeated interface
# reopens, then a check of whether the board survived both.
#
# A wedged board holds its UART but answers nothing on the network, and its
# receive DMA sits in state 4 with the eth0 interrupt count frozen.  The same
# sequence has also ended in kernel memory corruption, so the run checks the
# kernel log as well as the DMA state.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=dvr
source_address=
duration=30
streams=4
reopens=10
watch=

# Channel 1 of the shared three-channel DMA, which is the one this port drives.
csr5=0x101c1114
csr6=0x101c1118

usage()
{
	cat <<'EOF'
usage: tools/ethernet-rx-wedge-repro.sh [options]

Options:
  --target HOST       maintained Linux target (default: dvr)
  --source ADDRESS    bind traffic to this local address (default: the
                      address of the wired interface)
  --duration SECONDS  inbound TCP before the reopens (default: 30)
  --streams COUNT     parallel TCP streams (default: 4)
  --reopens COUNT     interface down/up cycles (default: 10)
  --watch PATH        also run this CSR5 poller on the board across the run

Exits 0 when the board survives, 1 when it wedges or the kernel reports an
error, and 2 on a setup problem.
EOF
}

positive_integer()
{
	case $2 in
		''|*[!0-9]*|0)
			echo "$1 must be a positive integer" >&2
			exit 2
			;;
	esac
}

while [ "$#" -gt 0 ]; do
	case $1 in
		--target|--source|--duration|--streams|--reopens|--watch)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			case $1 in
				--target) target=$2 ;;
				--source) source_address=$2 ;;
				--duration)
					positive_integer --duration "$2"
					duration=$2
					;;
				--streams)
					positive_integer --streams "$2"
					streams=$2
					;;
				--reopens)
					positive_integer --reopens "$2"
					reopens=$2
					;;
				--watch) watch=$2 ;;
			esac
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

for command in ssh scp iperf3 ping awk date mkdir networksetup ipconfig; do
	command -v "$command" > /dev/null 2>&1 || {
		echo "required host command not found: $command" >&2
		exit 2
	}
done

# Wi-Fi and the wired port can share this subnet, and only the wired path is
# under test.
wired_address()
{
	networksetup -listallhardwareports | awk '
		/^Hardware Port:/ {
			port = substr($0, 16)
			next
		}
		/^Device:/ && port !~ /Wi-Fi|Bluetooth|Thunderbolt|Bridge|VLAN/ {
			print $2
		}
	' | while read -r device; do
		address=$(ipconfig getifaddr "$device" 2>/dev/null) || continue
		[ -n "$address" ] && {
			echo "$address"
			break
		}
	done
}

[ -z "$source_address" ] && source_address=$(wired_address)
[ -z "$source_address" ] && {
	echo "no wired interface has an address; pass --source" >&2
	exit 2
}

# ssh ignores ConnectTimeout while ARP resolution hangs, so probe first.  An
# interface that has just come up costs the first packet to ARP resolution, so
# a single lost ping says nothing; only a run of them means the board is gone.
alive()
{
	attempt=1
	while [ "$attempt" -le 4 ]; do
		ping -q -S "$source_address" -c 1 -t 2 "$target" \
			> /dev/null 2>&1 && return 0
		attempt=$((attempt + 1))
	done
	return 1
}

remote()
{
	alive || return 1
	ssh -o BatchMode=yes -o ConnectTimeout=5 -b "$source_address" \
		"root@$target" "$@"
}

alive || {
	echo "$target is not answering before the run starts" >&2
	exit 2
}

output=$repo/artifacts/ethernet-tests/$(date -u +%Y%m%dT%H%M%SZ)-wedge
mkdir -p "$output"
echo "results: $output"

remote "printf 'ring '; ethtool -g eth0 | awk '
		/^Current hardware settings:/ { current = 1; next }
		current && /^RX:/ { print \$2; exit }'
	printf 'cmdline '; cat /proc/cmdline
	printf 'CSR5 '; devmem $csr5 32
	printf 'CSR6 '; devmem $csr6 32" | tee "$output/before.txt"

# The reopen loop outlives the SSH session that starts it, because taking eth0
# down takes that session with it.  It stops early on a suspended receive DMA.
cat > "$output/reopen.sh" <<EOF
#!/bin/sh
i=1
while [ "\$i" -le $reopens ]; do
	ip link set eth0 down
	sleep 2
	ip link set eth0 up
	sleep 5
	status=\$(devmem $csr5 32)
	state=\$(( (status & 0x000e0000) >> 17 ))
	irq=\$(grep eth0 /proc/interrupts | sed 's/^ *[0-9]*: *//' | cut -d' ' -f1)
	echo "reopen \$i CSR5 \$status RS \$state IRQ \$irq"
	[ "\$state" -eq 4 ] && {
		echo "WEDGED on reopen \$i"
		break
	}
	i=\$((i + 1))
done
echo finished
EOF
scp -q -o BatchMode=yes -o "BindAddress=$source_address" \
	"$output/reopen.sh" "root@$target:/tmp/reopen.sh"

[ -n "$watch" ] && {
	watch_seconds=$((duration + reopens * 8 + 30))
	remote "setsid sh -c '$watch $watch_seconds > /tmp/wedge-watch.csv 2>&1' \
		< /dev/null > /dev/null 2>&1 &"
	echo "poller running for ${watch_seconds}s"
}

remote 'iperf3 -s -D -1 -p 5450'
iperf3 -c "$target" -B "$source_address" -p 5450 -P "$streams" \
	-t "$duration" -i 0 > "$output/iperf3.txt" 2>&1 || {
	echo "FAIL: inbound traffic did not complete; results: $output" >&2
	exit 1
}
# The sender line carries the retransmit count, which is what a receive stall
# looks like from the host.
awk '/SUM.*(sender|receiver)/ { print "traffic: " $0 }' "$output/iperf3.txt"

alive || {
	echo "FAIL: the board stopped answering during traffic; results: $output" >&2
	exit 1
}

remote 'chmod +x /tmp/reopen.sh
	setsid sh -c "/tmp/reopen.sh > /tmp/reopen.log 2>&1" \
		< /dev/null > /dev/null 2>&1 &'
echo "reopening the interface $reopens times"

# Each cycle costs about seven seconds, and the board is unreachable for part
# of every one of them.  Report each cycle as it lands rather than at the end.
waited=0
shown=0
budget=$((reopens * 8 + 30))
while [ "$waited" -lt "$budget" ]; do
	sleep 5
	waited=$((waited + 5))
	progress=$(remote 'cat /tmp/reopen.log' 2>/dev/null) || continue
	lines=$(printf '%s\n' "$progress" | grep -c .)
	[ "$lines" -gt "$shown" ] && {
		printf '%s\n' "$progress" | sed -n "$((shown + 1)),\$p"
		shown=$lines
	}
	printf '%s\n' "$progress" | grep -q '^finished' && break
	printf '%s\n' "$progress" | grep -q '^WEDGED' && break
done

alive || {
	echo "FAIL: the board is unreachable after the reopens; results: $output" >&2
	echo "read /tmp/reopen.log and CSR5 over the serial console" >&2
	exit 1
}

remote 'cat /tmp/reopen.log' > "$output/reopen.log" 2>/dev/null

remote "printf 'CSR5 '; devmem $csr5 32" | tee "$output/after.txt"
remote 'dmesg | tail -40' > "$output/dmesg.txt" 2>/dev/null

grep -qE 'Internal error|Unable to handle|BUG:|Oops' "$output/dmesg.txt" && {
	echo "FAIL: the kernel reported an error; see $output/dmesg.txt" >&2
	grep -E 'Internal error|Unable to handle|BUG:|Oops' "$output/dmesg.txt" >&2
	exit 1
}

grep -q WEDGED "$output/reopen.log" && {
	echo "FAIL: the receive DMA suspended and did not resume" >&2
	exit 1
}

echo "PASS: the board survived $duration s of traffic and $reopens reopens"
