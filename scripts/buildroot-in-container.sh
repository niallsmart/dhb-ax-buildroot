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

# shellcheck source=scripts/lib.sh
. "$(dirname -- "$0")/lib.sh"

# Machine-local configuration, holding the values that a public repository
# must not carry.  Validate it here rather than leaving make to discover the
# problem: every failure below otherwise ends the same way, with an empty
# BR2_TARGET_GENERIC_ROOT_PASSWD, and an empty root password is not a build
# error -- Buildroot writes "root::" and produces an image anybody can log
# into over the UART.  A silent downgrade to passwordless is the one outcome
# worth spending a check on.
require_env_file "${DHB_AX_ENV:-/work/local.env}" DHB_AX_ROOT_PASSWD

# The make-side $(shell) below reads the plaintext from its environment.
# require_env_file exports it so make cannot silently generate root::.

# Keep the plaintext out of the defconfig and generated .config by expanding
# it only when make consumes BR2_TARGET_GENERIC_ROOT_PASSWD. Buildroot passes
# the value to host-mkpasswd during target finalization. Silent recipe output
# keeps that command out of the build log.
root_passwd_var='DHB_AX_ROOT_PASSWD=$(shell printf "%s" "$${DHB_AX_ROOT_PASSWD}")'

# Buildroot is mounted read-only, so every invocation is an out-of-tree build.
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output tree afterwards, but passing it every time is
# harmless and keeps the two calls identical.
br() {
	make --silent -C "$buildroot" O="$output" BR2_EXTERNAL="$external" \
		BR2_DL_DIR="$downloads" "$root_passwd_var" "$@"
}

check_root_password() {
	grep -qx 'BR2_TARGET_ENABLE_ROOT_LOGIN=y' "$output/.config" || return 0
	actual=$(sed -n 's/^root:\([^:]*\):.*/\1/p' "$output/target/etc/shadow")
	case $actual in
	'$1$'* | '$5$'* | '$6$'*) ;;
	*)
		echo "built root password is not a crypt hash" >&2
		return 1
		;;
	esac
	echo "root password verified: Buildroot crypt hash installed"
}

export_kernel_modules() {
	modules=$output/target/lib/modules
	set -- "$modules"/*
	if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
		echo "production rootfs must contain exactly one kernel module release" >&2
		return 1
	fi
	release=${1##*/}
	expected=$(sed -n \
		's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\([0-9][0-9.]*\)"$/\1/p' \
		"$defconfig_file")
	if [ "$release" != "$expected" ]; then
		echo "module release $release does not match configured kernel $expected" >&2
		return 1
	fi

	archive=$output/images/kernel-modules.tar
	# Buildroot's target tree belongs to its unprivileged build user. The
	# filesystem image corrects that ownership under fakeroot; do the same for
	# this separately exported system archive.
	tar --sort=name --numeric-owner --owner=0 --group=0 -C "$output/target" \
		-cf "$archive" lib/modules
	echo "kernel modules: $release -> $(basename "$archive")"
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
		check_root_password
		if [ "$build_config" = main ]; then
			export_kernel_modules
		fi
	fi
fi

# Copy out whatever the build produced.  A configure-only invocation leaves
# the images directory empty, which is not an error.
if [ -d "$output/images" ] && [ -n "$(ls -A "$output/images" 2>/dev/null)" ]; then
	echo
	echo "artifacts -> ${artifacts#/work/}/"
	for f in "$output"/images/*; do
		[ -f "$f" ] || continue
		name=$(basename "$f")
		temporary=$artifacts/.$name.$$
		install -m 0644 "$f" "$temporary"
		mv -f "$temporary" "$artifacts/$name"
		printf '  %s\n' "$name"
	done
fi
