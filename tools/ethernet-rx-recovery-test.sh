#!/bin/sh
# Exercise stmmac receive recovery with host-driven standard network tools.
#
# The board is the iperf3 server so every case drives inbound traffic, and the
# sender stays on the development host because a receive failure also takes
# away SSH.  A small receive ring forces the descriptor exhaustion that the
# repaired Receive Buffer Unavailable path has to recover from.
#
# stmmac leaves RUE masked in CSR7, so rx_buf_unav_irq stays at zero however
# often the ring runs dry.  Exhaustion is observed instead by polling the
# receive-process state in CSR5 with ethernet-rx-ring-watch on the board.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=dvr
duration=30
runs=3
soak=0
boot_profile=
source_address=
watch=/tmp/ethernet-rx-ring-watch

usage()
{
	cat <<'EOF'
usage: tools/ethernet-rx-recovery-test.sh [options]

Options:
  --target HOST        maintained Linux target (default: dvr)
  --duration SECONDS   duration of each short case (default: 30)
  --runs COUNT         repeated inbound TCP cases (default: 3)
  --soak SECONDS       optional final inbound TCP soak (default: disabled)
  --boot-profile NAME  dvr-boot profile for the warm-reboot case; without it
                       the reboot case is skipped
  --source ADDRESS     bind traffic to this local address (default: the
                       address of the wired interface)
  --watch PATH         CSR5 receive-state poller on the target
                       (default: /tmp/ethernet-rx-ring-watch)
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
		--target)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			target=$2
			shift 2
			;;
		--duration)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			positive_integer --duration "$2"
			duration=$2
			shift 2
			;;
		--runs)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			positive_integer --runs "$2"
			runs=$2
			shift 2
			;;
		--soak)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			positive_integer --soak "$2"
			soak=$2
			shift 2
			;;
		--boot-profile)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			boot_profile=$2
			shift 2
			;;
		--source)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			source_address=$2
			shift 2
			;;
		--watch)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			watch=$2
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

for command in uname ssh iperf3 ping awk date mkdir networksetup ipconfig route; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "required host command not found: $command" >&2
		exit 2
	}
done

if [ "$(uname -s)" != Darwin ]; then
	echo "run this benchmark from the macOS development host" >&2
	exit 2
fi

# Wi-Fi and the wired port sit on the same subnet here, and the measurement is
# only about the wired path, so every connection to the board is bound to the
# wired address rather than left to the service order.
wired_device()
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
			echo "$device $address"
			break
		}
	done
}

interface_for_address()
{
	for device in $(ifconfig -l); do
		[ "$(ipconfig getifaddr "$device" 2>/dev/null)" = "$1" ] && {
			echo "$device"
			return 0
		}
	done
	return 1
}

resolve()
{
	case $1 in
		*[!0-9.]*)
			dscacheutil -q host -a name "$1" |
				awk '$1 == "ip_address:" { print $2; exit }'
			;;
		*)
			echo "$1"
			;;
	esac
}

remote()
{
	ssh -o BatchMode=yes -o ConnectTimeout=5 -b "$source_address" \
		"root@$target" "$@"
}

# Closing the interface leaves the host holding an unresolved ARP entry, so
# probe with ping until the board answers at layer 2 and only then with SSH.
wait_for_target()
{
	waited=0
	while [ "$waited" -lt 180 ]; do
		ping -q -S "$source_address" -c 1 -t 2 "$target" > /dev/null 2>&1 &&
			remote true > /dev/null 2>&1 && return 0
		sleep 3
		waited=$((waited + 3))
	done
	echo "target did not come back after $1" >&2
	exit 1
}

# The receive ring has to be small enough that ordinary inbound traffic runs
# the descriptors out, and it has to have been selected deliberately.
check_ring()
{
	ring_size=$(remote 'ethtool -g eth0' | awk '
		/^Current hardware settings:/ { current = 1; next }
		current && /^RX:/ { print $2; exit }
	')
	case $ring_size in
		64|256) ;;
		*)
			echo "target RX ring is $ring_size; boot with 64 or 256 descriptors" >&2
			exit 2
			;;
	esac

	cmdline=$(remote 'cat /proc/cmdline')
	case " $cmdline " in
		*" stmmac.rx_ring_size=$ring_size "*) ;;
		*)
			echo "RX ring was not selected by stmmac.rx_ring_size at boot" >&2
			exit 2
			;;
	esac
}

# CSR6 bit 24 is DFF.  With it set the MAC holds a frame in the receive FIFO
# when no descriptor is free instead of flushing it, so it has to survive every
# reopen of the interface.
check_dff()
{
	csr6=$(remote 'devmem 0x101c1118 32')
	[ -z "$csr6" ] && {
		echo "FAIL: could not read CSR6 after $1" >&2
		exit 1
	}
	[ $((csr6 & 0x01000000)) -eq 0 ] && {
		echo "FAIL: CSR6 DFF is clear after $1: $csr6" >&2
		exit 1
	}
	:
}

# Receive state 4 is a suspended DMA.  It is expected while the ring is empty
# and has to clear once the driver refills and writes receive poll demand.
check_dma_running()
{
	csr5=$(remote 'devmem 0x101c1114 32')
	[ -z "$csr5" ] && {
		echo "FAIL: could not read CSR5 after $1" >&2
		exit 1
	}
	[ $(( (csr5 & 0x000e0000) >> 17 )) -eq 4 ] && {
		echo "FAIL: RX DMA still suspended after $1: $csr5" >&2
		exit 1
	}
	:
}

# The poller reads CSR5 through /dev/mem and reports how often and how long
# the receive process sits suspended, which no standard interface exposes.
check_watch()
{
	remote "test -x $watch" || {
		echo "$watch is missing on $target; build and install it with:" >&2
		echo "  docker run --rm -v dhb-ax-br-main-output:/output \\" >&2
		echo "    -v \"\$PWD/tools\":/src:ro -v \"\$PWD/artifacts/local/bin\":/out \\" >&2
		echo "    dhb-ax-buildroot:bookworm \\" >&2
		echo "    /output/host/bin/arm-buildroot-linux-musleabihf-gcc -O2 -static \\" >&2
		echo "    -o /out/ethernet-rx-ring-watch /src/ethernet-rx-ring-watch.c" >&2
		echo "  scp artifacts/local/bin/ethernet-rx-ring-watch root@$target:$watch" >&2
		exit 2
	}
}

watch_value()
{
	awk -F= -v key="# $2" '$1 == key { print $2; exit }' "$1"
}

start_watch()
{
	remote "setsid sh -c '$watch $2 > /tmp/watch-$1.csv 2>&1' \
		< /dev/null > /dev/null 2>&1 &"
}

# The poller outlives the traffic it watches, and writes its summary as it
# exits.
collect_watch()
{
	waited=0
	while [ "$waited" -lt 90 ]; do
		remote "grep -q '^# state4_entries=' /tmp/watch-$1.csv" \
			2>/dev/null && break
		sleep 2
		waited=$((waited + 2))
	done
	remote "grep '^#' /tmp/watch-$1.csv" > "$output/$1-watch.txt" 2>/dev/null

	entries=$(watch_value "$output/$1-watch.txt" state4_entries)
	[ -z "$entries" ] && {
		echo "FAIL: $1: the poller wrote no summary" >&2
		exit 1
	}
	[ "$(watch_value "$output/$1-watch.txt" rps_seen)" = 1 ] && {
		echo "FAIL: $1: the receive process stopped" >&2
		exit 1
	}
	[ "$entries" -gt 0 ] && exhaustion_seen=1
	record "$1: state4 entries $entries, suspended $(watch_value "$output/$1-watch.txt" state4_s)s of $(watch_value "$output/$1-watch.txt" elapsed_s)s, longest $(watch_value "$output/$1-watch.txt" longest_state4_s)s, rps_seen $(watch_value "$output/$1-watch.txt" rps_seen)"
}

snapshot()
{
	remote '
		date -u
		uname -a
		cat /proc/cmdline
		ethtool -g eth0
		ethtool -c eth0
		printf "CSR5: "
		devmem 0x101c1114 32
		printf "CSR6: "
		devmem 0x101c1118 32
		for statistic in /sys/class/net/eth0/statistics/*; do
			printf "%s: %s\n" "${statistic##*/}" "$(cat "$statistic")"
		done
		ethtool -S eth0
		grep NET_RX /proc/softirqs
		grep -iE "eth|gmac|stmmac" /proc/interrupts
		cat /proc/stat
		cat /proc/net/snmp
		cat /proc/net/netstat
	' > "$output/$1.txt"
}

counter()
{
	awk -v key="$2:" '$1 == key { print $2; exit }' "$1"
}

# Report every fault, drop and recovery counter that moved between two
# snapshots, without depending on the exact names this driver exports.
deltas()
{
	awk '
		FNR == NR { before[$1] = $2; next }
		$1 ~ /(err|drop|fifo|missed|overflow|unav|stopped|abnormal)/ &&
		$2 ~ /^[0-9]+$/ && ($1 in before) && $2 != before[$1] {
			printf "  %s %s -> %s\n", $1, before[$1], $2
		}
	' "$1" "$2"
}

record()
{
	echo "$*" | tee -a "$output/results.txt"
}

# A corrupted frame that the MAC accepted is a failure however the run ends.
check_case()
{
	for error_counter in rx_crc_errors rx_frame_errors rx_length_errors; do
		before=$(counter "$output/$1.txt" "$error_counter")
		after=$(counter "$output/$2.txt" "$error_counter")
		[ -z "$after" ] && continue
		[ "$after" -ne "$before" ] && {
			echo "FAIL: $3: $error_counter $before -> $after" >&2
			exit 1
		}
	done

	before=$(counter "$output/$1.txt" rx_bytes)
	after=$(counter "$output/$2.txt" rx_bytes)
	[ "$after" -le "$before" ] && {
		echo "FAIL: $3 received nothing ($before -> $after)" >&2
		exit 1
	}
	record "$3: rx_bytes +$((after - before))"

	deltas "$output/$1.txt" "$output/$2.txt" >> "$output/results.txt"
	previous=$2
}

run_case()
{
	name=$1
	port=$2
	case_duration=$3
	mode=$4
	pings=$((case_duration * 5))

	remote "iperf3 -s -D -1 -p $port"
	start_watch "$name" $((case_duration + 8))
	ping -q -S "$source_address" -i 0.2 -c "$pings" "$target" \
		> "$output/$name-ping.txt" 2>&1 &
	ping_pid=$!

	set +e
	case $mode in
		tcp)
			iperf3 -c "$target" -B "$source_address" -p "$port" -P 4 \
				-t "$case_duration" -i 0 \
				> "$output/$name-iperf3.txt" 2>&1
			;;
		udp)
			iperf3 -c "$target" -B "$source_address" -p "$port" \
				-u -b 0 -l 64 -P 4 -t "$case_duration" -i 0 \
				> "$output/$name-iperf3.txt" 2>&1
			;;
		bidir)
			iperf3 -c "$target" -B "$source_address" -p "$port" \
				--bidir -P 4 -t "$case_duration" -i 0 \
				> "$output/$name-iperf3.txt" 2>&1
			;;
	esac
	case_status=$?
	wait "$ping_pid" || case_status=1
	set -e
	snapshot "$name-after"
	collect_watch "$name"

	[ "$case_status" -ne 0 ] && {
		echo "FAIL: $name traffic or ping failed; results: $output" >&2
		exit 1
	}
	check_case "$previous" "$name-after" "$name"
	check_dff "$name"
	check_dma_running "$name"
	echo "$name complete"
}

# Closing and reopening the interface releases and reallocates the descriptor
# ring.  The command outlives the SSH session it arrives on, because taking
# eth0 down takes that session with it.
reopen_interface()
{
	remote sh -s <<'EOF' > /dev/null
set -eu
address=$(ip -o -4 addr show dev eth0 | awk '{ print $4 }')
gateway=$(ip route show default | awk '{ print $3 }')
cat > /tmp/reopen-eth0.sh <<SCRIPT
#!/bin/sh
sleep 1
ip link set eth0 down
sleep 3
ip link set eth0 up
if ! ip -o -4 addr show dev eth0 | grep -q "inet "; then
	ip addr add $address dev eth0
fi
if ! ip route show default | grep -q .; then
	ip route add default via $gateway dev eth0
fi
SCRIPT
chmod +x /tmp/reopen-eth0.sh
setsid /tmp/reopen-eth0.sh > /tmp/reopen-eth0.log 2>&1 &
EOF
	wait_for_target "the interface reopen"
}

if [ -z "$source_address" ]; then
	wired=$(wired_device)
	[ -z "$wired" ] && {
		echo "no wired interface has an address; pass --source" >&2
		exit 2
	}
	source_address=${wired#* }
fi
source_interface=$(interface_for_address "$source_address") || {
	echo "no interface holds $source_address" >&2
	exit 2
}

target_address=$(resolve "$target")
[ -z "$target_address" ] && {
	echo "cannot resolve $target" >&2
	exit 2
}
route_interface=$(route -n get "$target_address" |
	awk '$1 == "interface:" { print $2; exit }')
[ "$route_interface" != "$source_interface" ] && {
	echo "route to $target_address uses $route_interface, not $source_interface" >&2
	exit 2
}

exhaustion_seen=0
check_ring
check_watch
check_dff boot

output=$repo/artifacts/ethernet-tests/$(date -u +%Y%m%dT%H%M%SZ)-rx$ring_size
mkdir -p "$output"

echo "results: $output"
record "target: $target ($target_address), RX ring: $ring_size, CSR6: $csr6"
record "source: $source_address on $source_interface"
record "cmdline: $cmdline"
ping -q -S "$source_address" -c 3 "$target" > "$output/warmup-ping.txt"
snapshot before
previous=before

index=1
while [ "$index" -le "$runs" ]; do
	run_case "tcp-$index" $((5200 + index)) "$duration" tcp
	index=$((index + 1))
done
run_case udp-small 5210 "$duration" udp
run_case bidirectional 5211 "$duration" bidir

if [ "$soak" -gt 0 ]; then
	run_case tcp-soak 5212 "$soak" tcp
fi

reopen_interface
check_dff "the interface reopen"
snapshot reopen
previous=reopen
run_case tcp-after-reopen 5213 "$duration" tcp

if remote 'ethtool -r eth0' > "$output/link-flap.txt" 2>&1; then
	wait_for_target "the link flap"
	check_dff "the link flap"
	snapshot link-flap
	previous=link-flap
	run_case tcp-after-link-flap 5214 "$duration" tcp
else
	record "link flap: ethtool -r is unsupported on this interface; skipped"
fi

if [ -n "$boot_profile" ]; then
	"$repo/tools/dvr-boot.sh" --bootarg "stmmac.rx_ring_size=$ring_size" \
		"$boot_profile" > "$output/warm-reboot.txt" 2>&1
	wait_for_target "the warm reboot"
	check_ring
	check_dff "the warm reboot"
	snapshot warm-reboot
	previous=warm-reboot
	run_case tcp-after-reboot 5215 "$duration" tcp
else
	record "warm reboot: no --boot-profile given; skipped"
fi

snapshot after
# A warm reboot resets these, so report where the run ended rather than a
# difference that may span the reboot.
record "final rx_buf_unav_irq: $(counter "$output/after.txt" rx_buf_unav_irq)"
record "final rx_process_stopped_irq: $(counter "$output/after.txt" rx_process_stopped_irq)"

[ "$exhaustion_seen" -eq 0 ] && {
	echo "INCONCLUSIVE: the receive process never suspended, so the refill and poll-demand path went untested" >&2
	exit 2
}

record "PASS: descriptor exhaustion occurred and receive recovered in every case"
