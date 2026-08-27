#!/bin/sh
# macOS wrapper around the containerised Buildroot build.  Run with --help for
# the command list.
#
# Buildroot's output tree is ~100k small files.  On macOS a bind mount makes
# that painfully slow, so the caches and output live in named volumes instead.
#

set -eu

usage()
{
	cat <<EOF
usage: $0 [--config NAME] [target ...]. # run buildroot target (or default)
       $0 [--config NAME] --shell       # run shell
       $0 [--config NAME] --clean       # drops the selected output volume
       $0 --distclean                   # drops every output

Configurations:
  main       production image (default)
  toolchain  build and stage the shared cross-toolchain SDK
  minimal    self-contained UART diagnostic image

EOF
}

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
buildroot_src=$repo/buildroot/buildroot-2026.02.3
image=dhb-ax-buildroot:bookworm
volume_dl=dhb-ax-br-dl
volume_ccache=dhb-ax-br-ccache
build_config=main

if [ "${1:-}" = "--config" ]; then
	if [ "$#" -lt 2 ]; then
		usage > /dev/stderr
		exit 2
	fi
	build_config=$2
	shift 2
fi

case $build_config in
main|toolchain|minimal)
	volume_output=dhb-ax-br-${build_config}-output
	;;
*)
	usage > /dev/stderr
	exit 2
	;;
esac

# Each of these options should be possible without requiring a local.env, so
# they are processed before require_env_file
#
# The --clean and --distclean options are named after Buildroot's own targets,
# which draw the line in the same place: clean deletes what the build produced,
# distclean also drops the downloads.
case "${1:-}" in
-h | --help)
	usage
	exit 0
	;;
--clean)
	echo "removing volume $volume_output"
	docker volume rm -f "$volume_output"
	exit 0
	;;
--distclean)
	volumes=`docker volume ls --format '{{.Name}}' | grep '^dhb-ax'`
	echo "removing volumes:\n$volumes"
	docker volume rm -f $volumes
	exit 0
	;;
esac

. "$repo/scripts/lib.sh"

require_env_file "$repo/local.env"

if [ ! -f "$buildroot_src/Makefile" ]; then
	echo "no Buildroot source at $buildroot_src" >&2
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

docker build \
	--file "$repo/scripts/Dockerfile.buildroot" \
	--tag "$image" \
	"$repo/scripts"

# Buildroot's default BR2_CCACHE_DIR is $HOME/.buildroot-ccache.
docker run --rm $tty_flags \
	--env "BUILD_CONFIG=$build_config" \
	--mount "type=bind,source=$repo,target=/work,readonly" \
	--mount "type=bind,source=$repo/artifacts,target=/work/artifacts" \
	--mount "type=bind,source=$repo/br2-external,target=/work/br2-external" \
	--mount "type=bind,source=$buildroot_src,target=/buildroot,readonly" \
	--mount "type=volume,source=$volume_output,target=/output" \
	--mount "type=volume,source=$volume_dl,target=/dl" \
	--mount "type=volume,source=$volume_ccache,target=/home/br/.buildroot-ccache" \
	"$image" \
	"$cmd" "$@"
