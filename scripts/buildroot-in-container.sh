#!/bin/sh
# Drive Buildroot from inside the container.  Called by scripts/buildroot.sh.
#
#   buildroot-in-container.sh [target ...]
#
# With no target: always reapply and verify the maintained defconfig, then
# build everything. This prevents removed packages and old local menuconfig
# choices from leaking out of the persistent output volume into an image.
set -eu

buildroot=/work/buildroot/buildroot-2026.02.3
output=${HOME}/output
downloads=${HOME}/downloads
external=/work/br2-external
build_config=${BUILD_CONFIG:-main}

case $build_config in
main)
	defconfig=dhb_ax_defconfig
	artifacts=/work/artifacts/buildroot
	;;
toolchain)
	defconfig=dhb_ax_toolchain_defconfig
	artifacts=/work/artifacts/toolchain
	;;
minimal)
	defconfig=dhb_ax_minimal_defconfig
	artifacts=/work/artifacts/buildroot-minimal
	;;
*)
	echo "unknown BUILD_CONFIG: $build_config" >&2
	exit 2
	;;
esac

defconfig_file=$external/configs/$defconfig
check_dotconfig=$buildroot/support/scripts/check-dotconfig.py
# Keep finished images outside the Buildroot output volume so they are easy to
# stage and survive container recreation. The parent is gitignored.

mkdir -p "$artifacts"

# Buildroot is mounted read-only, so every invocation is an out-of-tree build.
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output tree afterwards, but passing it every time is
# harmless and keeps the two calls identical.
br() {
	make --silent -C "$buildroot" O="$output" BR2_EXTERNAL="$external" \
		BR2_DL_DIR="$downloads" \
		LINUX_OVERRIDE_SRCDIR="${LINUX_OVERRIDE_SRCDIR:-}" "$@"
}

if [ "$#" -gt 0 ]; then
	br "$@"
	case " $* " in
	*" $defconfig "*) "$check_dotconfig" "$output/.config" "$defconfig_file" ;;
	esac
else
	br "$defconfig"
	"$check_dotconfig" "$output/.config" "$defconfig_file"
	if [ "$build_config" = toolchain ]; then
		br -j"$(nproc)" dhb-ax-sdk
	else
		br -j"$(nproc)" all
	fi
fi

# A configure-only invocation leaves the images directory empty, which is not
# an error.
for image in "$output"/images/*; do
	[ -f "$image" ] || continue
	cp "$image" "$artifacts/"
done
