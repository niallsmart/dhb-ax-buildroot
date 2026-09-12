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
usage: $0 [--toolchain] [target ...] # run Buildroot target (or default)
       $0 [--toolchain] --shell     # run shell
       $0 --distclean              # drops every build volume

The default builds dhb_ax_defconfig. Use --toolchain to build and install
the shared cross-toolchain SDK (dhb_ax_toolchain_defconfig).

EOF
}

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
buildroot_src=$repo/buildroot/buildroot-2026.02.3
image=dhb-ax-buildroot:bookworm
volume_dl=dhb-ax-br-dl
volume_ccache=dhb-ax-br-ccache
volume_sdk=dhb-ax-br-sdk
volume_output=dhb-ax-br-output
container_home=/home/br
toolchain=false

if [ "${1:-}" = "--toolchain" ]; then
	toolchain=true
	volume_output=dhb-ax-br-toolchain-output
	shift
fi

# These options do not require local.env, so process them first.
case "${1:-}" in
-h | --help)
	usage
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

if ! "$toolchain"; then
	"$repo/scripts/kernel-sources" status >/dev/null
fi

# menuconfig and friends require a terminal; --shell uses one when available.
# dhb_ax_defconfig is not interactive, so match the curses targets by name
# rather than by a "*config" glob.
tty_flags=
cmd=/work/scripts/buildroot-in-container.sh
case "${1:-}" in
--shell)
	tty_flags=-i
	[ -t 0 ] && tty_flags="-t $tty_flags"
	cmd=/bin/bash
	shift
	;;
*menuconfig | *nconfig | *xconfig | *gconfig)
	if [ -t 0 ]; then
		tty_flags=-it
	else
		echo "$1 needs a terminal; run this from an interactive shell" >&2
		exit 1
	fi
	;;
esac

docker build \
	--file "$repo/scripts/Dockerfile.buildroot" \
	--tag "$image" \
	"$repo/scripts"

if "$toolchain"; then
	sdk_mount="type=volume,source=$volume_sdk,target=$container_home/sdk"
else
	sdk_mount="type=volume,source=$volume_sdk,target=$container_home/sdk,readonly"
fi

mkdir -p "$repo/artifacts"

docker run --rm $tty_flags \
	--env "BUILD_TOOLCHAIN=$toolchain" \
	--env "GIT_CEILING_DIRECTORIES=/work" \
	--mount "type=bind,source=$repo,target=/work,readonly" \
	--mount "type=bind,source=$repo/artifacts,target=/work/artifacts" \
	--mount "type=bind,source=$repo/br2-external,target=/work/br2-external" \
	--mount "type=volume,source=$volume_output,target=$container_home/output" \
	--mount "type=volume,source=$volume_dl,target=$container_home/downloads" \
	--mount "type=volume,source=$volume_ccache,target=$container_home/ccache" \
	--mount "$sdk_mount" \
	"$image" \
	"$cmd" "$@"
