#!/bin/sh
# Build the static ARM RX-ring sampler and iperf3 for Ethernet diagnostics.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$repo/artifacts/diagnostics/ethernet-rx-tools
sdk=$repo/artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz

[ -r "$sdk" ] || {
	echo "missing SDK archive: $sdk" >&2
	exit 1
}

mkdir -p "$output"

docker run --rm \
	--mount "type=bind,source=$repo,target=/work" \
	--mount type=volume,source=dhb-ax-br-dl,target=/dl,readonly \
	--workdir /work \
	dhb-ax-buildroot:bookworm \
	/bin/sh -ec '
		rm -rf /tmp/dhb-ax-ethernet-sdk
		mkdir /tmp/dhb-ax-ethernet-sdk
		tar -xzf artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz \
			-C /tmp/dhb-ax-ethernet-sdk
		/tmp/dhb-ax-ethernet-sdk/arm-buildroot-linux-musleabihf_sdk-buildroot/bin/arm-buildroot-linux-musleabihf-gcc \
			-static -O2 -Wall -Wextra -Werror \
			-o artifacts/diagnostics/ethernet-rx-tools/rx-ring-watch \
			tools/ethernet-rx-ring-watch.c
		rm -rf /tmp/dhb-ax-iperf3
		mkdir /tmp/dhb-ax-iperf3
		tar -xzf /dl/iperf3/iperf-3.20.tar.gz -C /tmp/dhb-ax-iperf3 \
			--strip-components=1
		cd /tmp/dhb-ax-iperf3
		CC=/tmp/dhb-ax-ethernet-sdk/arm-buildroot-linux-musleabihf_sdk-buildroot/bin/arm-buildroot-linux-musleabihf-gcc \
			./configure --host=arm-buildroot-linux-musleabihf \
			--enable-static --disable-shared --without-openssl
		make -j2
		/tmp/dhb-ax-ethernet-sdk/arm-buildroot-linux-musleabihf_sdk-buildroot/bin/arm-buildroot-linux-musleabihf-gcc \
			-static -o /work/artifacts/diagnostics/ethernet-rx-tools/iperf3 \
			src/iperf3-main.o src/.libs/libiperf.a -pthread -lm
		/tmp/dhb-ax-ethernet-sdk/arm-buildroot-linux-musleabihf_sdk-buildroot/bin/arm-buildroot-linux-musleabihf-strip \
			/work/artifacts/diagnostics/ethernet-rx-tools/iperf3
	'
