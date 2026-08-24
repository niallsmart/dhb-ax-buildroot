#!/bin/sh
# Build the parameterized RAM-only UART stub with the shared Buildroot SDK.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
image=dhb-ax-buildroot:bookworm

if [ "${DHB_AX_STUB_CONTAINER:-}" != 1 ]; then
	mkdir -p "$repo/artifacts/uart-baud-handoff"
	exec docker run --rm \
		--user "$(id -u):$(id -g)" \
		--env DHB_AX_STUB_CONTAINER=1 \
		--env HOME=/tmp \
		--entrypoint /work/tools/uart-baud-handoff/build.sh \
		--mount "type=bind,source=$repo,target=/work,readonly" \
		--mount "type=bind,source=$repo/artifacts/uart-baud-handoff,target=/out" \
		"$image"
fi

sdk_archive=/work/artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz
source_dir=/work/tools/uart-baud-handoff
temporary=$(mktemp -d /tmp/dhb-ax-uart-stub.XXXXXX)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

tar -xzf "$sdk_archive" -C "$temporary"
sdk=$temporary/arm-buildroot-linux-musleabihf_sdk-buildroot
"$sdk/relocate-sdk.sh"

prefix=$sdk/bin/arm-buildroot-linux-musleabihf
cc=$prefix-gcc
ld=$prefix-ld
objcopy=$prefix-objcopy
objdump=$prefix-objdump
readelf=$prefix-readelf
nm=$prefix-nm

name=uart-stub-template
"$cc" -c -x assembler-with-cpp -mcpu=cortex-a9 -marm \
	-o "/out/$name.o" "$source_dir/stub.S"
"$ld" --build-id=none -T "$source_dir/link.ld" \
	-o "/out/$name.elf" "/out/$name.o"
if "$readelf" -rW "/out/$name.elf" | grep -q 'Relocation section'; then
	echo "$name contains relocations" >&2
	exit 1
fi
"$objcopy" -O binary --only-section=.text --gap-fill=0 --pad-to=0x400 \
	"/out/$name.elf" "/out/$name.bin"
[ "$(wc -c < "/out/$name.bin")" -eq 1024 ]
"$objdump" -dr "/out/$name.elf" > "/out/$name.dis"

sha256sum "/out/$name.bin"

loader=uart-ymodem-g-loader
"$cc" -c -Os -mcpu=cortex-a9 -marm -ffreestanding -fno-builtin \
	-fno-pic -fno-pie -fno-stack-protector -fno-unwind-tables \
	-fno-asynchronous-unwind-tables -o "/out/$loader.o" "$source_dir/loader.c"
"$ld" --build-id=none -T "$source_dir/loader-link.ld" \
	-o "/out/$loader.elf" "/out/$loader.o"
if "$readelf" -rW "/out/$loader.elf" | grep -q 'Relocation section'; then
	echo "$loader contains relocations" >&2
	exit 1
fi
"$objcopy" -O binary --gap-fill=0 --pad-to=0x83004000 \
	"/out/$loader.elf" "/out/$loader.bin"
[ "$(wc -c < "/out/$loader.bin")" -eq 16384 ]
"$objdump" -dr "/out/$loader.elf" > "/out/$loader.dis"
"$readelf" -aW "/out/$loader.elf" > "/out/$loader.readelf"
if "$nm" -u "/out/$loader.elf" | grep -q .; then
	echo "$loader contains undefined symbols" >&2
	"$nm" -u "/out/$loader.elf" >&2
	exit 1
fi

sha256sum "/out/$loader.bin"
