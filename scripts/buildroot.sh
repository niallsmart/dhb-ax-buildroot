#!/bin/sh
# macOS wrapper around the containerised Buildroot build.
#
#   buildroot.sh [target ...]      default: dhb_ax_defconfig, then all
#   buildroot.sh menuconfig        interactive; needs a tty
#   buildroot.sh savedefconfig     write configs/dhb_ax_defconfig back out
#   buildroot.sh --clean           drop the output and download volumes
#
# Buildroot's output tree is ~100k small files.  On macOS a bind mount makes
# that painfully slow, so the download cache and the output directory live in
# Docker named volumes instead.  The repository is bind-mounted read-write at
# /work because Buildroot reads the pinned kernel tarball from it and writes
# artifacts back.
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
buildroot_dir=$workspace/buildroot/buildroot-2026.02.3

image=dhb-ax-buildroot:bookworm
dl_volume=dhb-ax-br-dl
out_volume=dhb-ax-br-output

if [ "${1:-}" = "--clean" ]; then
	echo "removing volumes $out_volume and $dl_volume"
	docker volume rm -f "$out_volume" "$dl_volume"
	exit 0
fi

if [ ! -f "$buildroot_dir/Makefile" ]; then
	echo "no Buildroot source at $buildroot_dir" >&2
	echo "run scripts/bootstrap-sources.sh first" >&2
	exit 1
fi

# menuconfig and friends need a terminal; everything else does not, and
# allocating one breaks the script when stdout is a pipe.  Note that
# dhb_ax_defconfig is *not* interactive, so match the curses targets by name
# rather than by a "*config" glob.
tty_flags=
case "${1:-}" in
*menuconfig | *nconfig | *xconfig | *gconfig)
	if [ -t 0 ]; then
		tty_flags=-it
	else
		echo "$1 needs a terminal; run this from an interactive shell" >&2
		exit 1
	fi
	;;
esac

if [ "${1:-}" = "--shell" ]; then
	tty_flags=-i
	[ -t 0 ] && tty_flags="-t $tty_flags"
	cmd=/bin/bash
	shift
else
	cmd=/work/scripts/buildroot-in-container.sh
fi

docker build -t "$image" "$workspace/scripts"


docker run --rm $tty_flags \
	--mount "type=bind,source=$buildroot_dir,target=/buildroot,readonly" \
	--mount "type=bind,source=$workspace,target=/work" \
	--mount "type=volume,source=$out_volume,target=/output" \
	--mount "type=volume,source=$dl_volume,target=/dl" \
	"$image" \
	"$cmd" "$@"
