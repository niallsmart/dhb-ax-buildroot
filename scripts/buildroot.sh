#!/bin/sh
# macOS wrapper around the containerised Buildroot build.  Run with --help for
# the command list.
#
# Buildroot's output tree is ~100k small files.  On macOS a bind mount makes
# that painfully slow, so the download cache and the output directory live in
# Docker named volumes instead.
#
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
buildroot_dir=$workspace/buildroot/buildroot-2026.02.3

image=dhb-ax-buildroot:bookworm
dl_volume=dhb-ax-br-dl
ccache_volume=dhb-ax-br-ccache

build_config=main
if [ "${1:-}" = "--config" ]; then
	if [ "$#" -lt 2 ]; then
		echo "--config needs one of: main, toolchain, minimal" >&2
		exit 2
	fi
	build_config=$2
	shift 2
fi

case $build_config in
main)
	defconfig=dhb_ax_defconfig
	out_volume=dhb-ax-br-output
	;;
toolchain)
	defconfig=dhb_ax_toolchain_defconfig
	out_volume=dhb-ax-br-toolchain-output
	;;
minimal)
	defconfig=dhb_ax_minimal_defconfig
	out_volume=dhb-ax-br-minimal-output
	;;
*)
	echo "unknown configuration: $build_config" >&2
	echo "expected one of: main, toolchain, minimal" >&2
	exit 2
	;;
esac

usage()
{
	cat <<EOF
usage: $0 [--config NAME] [target ...]
       $0 [--config NAME] --clean
       $0 --distclean
       $0 [--config NAME] --shell

Configurations:
  main       production image (default)
  toolchain  build and stage the shared cross-toolchain SDK
  minimal    self-contained UART diagnostic image

With no target, reapply and verify the selected defconfig, then build it.
--clean drops only the selected output volume. --distclean drops every output
volume, the shared downloads volume, and the shared compiler cache.

EOF
}

# All of these run before require_env_file: none of them read local.env, and
# both asking for usage and dropping a volume have to work on a fresh checkout.
#
# --clean and --distclean are named after Buildroot's own targets, which draw
# the line in the same place: clean deletes what the build produced, distclean
# also drops the downloads.
case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
--clean)
	echo "removing volume $out_volume; keeping $dl_volume"
	docker volume rm -f "$out_volume"
	exit 0
	;;
--distclean)
	volumes="dhb-ax-br-output dhb-ax-br-toolchain-output dhb-ax-br-minimal-output $dl_volume $ccache_volume"
	echo "removing volumes $volumes"
	# shellcheck disable=SC2086 # Each word is one fixed volume name.
	docker volume rm -f $volumes
	exit 0
	;;
esac

. "$workspace/scripts/lib.sh"

require_env_file "$workspace/local.env"

if [ ! -f "$buildroot_dir/Makefile" ]; then
	echo "no Buildroot source at $buildroot_dir" >&2
	echo "run scripts/bootstrap-sources.sh first" >&2
	exit 1
fi

if [ ! -f "$workspace/br2-external/configs/$defconfig" ]; then
	echo "no $build_config defconfig at br2-external/configs/$defconfig" >&2
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

# savedefconfig rewrites br2-external/configs/dhb_ax_defconfig; other targets
# cannot modify tracked source
br2_external_mode=,readonly
case " $* " in
*" savedefconfig "*) br2_external_mode= ;;
esac

if [ "${1:-}" = "--shell" ]; then
	tty_flags=-i
	[ -t 0 ] && tty_flags="-t $tty_flags"
	cmd=/bin/bash
	shift
else
	cmd=/work/scripts/buildroot-in-container.sh
fi

docker build \
	--file "$workspace/scripts/Dockerfile.buildroot" \
	--tag "$image" \
	"$workspace/scripts"

# Buildroot's default BR2_CCACHE_DIR is $HOME/.buildroot-ccache.
docker run --rm $tty_flags \
	--env "BUILD_CONFIG=$build_config" \
	--mount "type=bind,source=$workspace,target=/work,readonly" \
	--mount "type=bind,source=$workspace/br2-external,target=/work/br2-external$br2_external_mode" \
	--mount "type=bind,source=$workspace/artifacts,target=/work/artifacts" \
	--mount "type=bind,source=$buildroot_dir,target=/buildroot,readonly" \
	--mount "type=volume,source=$out_volume,target=/output" \
	--mount "type=volume,source=$dl_volume,target=/dl" \
	--mount "type=volume,source=$ccache_volume,target=/home/br/.buildroot-ccache" \
	"$image" \
	"$cmd" "$@"
