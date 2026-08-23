#!/bin/sh
# Drive Buildroot from inside the container.  Called by scripts/buildroot.sh.
#
#   buildroot-in-container.sh [target ...]
#
# With no target: always reapply and verify the maintained defconfig, then
# build everything. This prevents removed packages and old local menuconfig
# choices from leaking out of the persistent output volume into an image.
set -eu

# Buildroot cannot be built as root: several host packages -- GNU tar first --
# have a configure check that refuses outright.  The container starts as root
# only so it can take ownership of the output, download and ccache volumes,
# which come up owned by root the first time they are created. Everything after
# this runs as br.
if [ "$(id -u)" = 0 ]; then
	mkdir -p /output /dl /home/br/.buildroot-ccache
	for d in /output /dl /home/br/.buildroot-ccache; do
		[ "$(stat -c %u "$d")" = 1000 ] || chown -R br:br "$d"
	done
	exec setpriv --reuid=br --regid=br --init-groups \
		env HOME=/home/br LANG="${LANG:-C.UTF-8}" \
		LC_ALL="${LC_ALL:-C.UTF-8}" "$0" "$@"
fi

buildroot=${BUILDROOT:-/buildroot}
output=${BR_OUTPUT:-/output}
external=${BR2_EXTERNAL:-/work/br2-external}
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
sdk_tarball=arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz
# Keep finished images outside the Buildroot output volume so they are easy to
# stage and survive container recreation. The parent is gitignored.

test -f "$buildroot/Makefile"
test -f "$external/external.desc"
if [ ! -f "$defconfig_file" ]; then
	echo "no $build_config defconfig at $defconfig_file" >&2
	exit 1
fi
mkdir -p "$output" /dl "$artifacts"

# The main post-image script once paired its kernel with the minimal DTB.
# Remove that non-bootable side product from persistent outputs until every
# main output volume in use has been rebuilt or cleaned after this migration.
if [ "$build_config" = main ]; then
	rm -f \
		"$output/images/uImage-hi3531-dhb-ax-minimal" \
		"$output/images/zImage-hi3531-dhb-ax-minimal-appended-dtb" \
		"$artifacts/uImage-hi3531-dhb-ax-minimal" \
		"$artifacts/zImage-hi3531-dhb-ax-minimal-appended-dtb"
fi

# shellcheck source=scripts/lib.sh
. "$(dirname -- "$0")/lib.sh"

# Machine-local configuration, holding the values that a public repository
# must not carry.  Validate it here rather than leaving make to discover the
# problem: every failure below otherwise ends the same way, with an empty
# BR2_TARGET_GENERIC_ROOT_PASSWD, and an empty root password is not a build
# error -- Buildroot writes "root::" and produces an image anybody can log
# into over the UART.  A silent downgrade to passwordless is the one outcome
# worth spending a check on.
require_env_file "${DHB_AX_ENV:-/work/local.env}"

case "${DHB_AX_ROOT_PASSWD:-}" in
'')
	echo "$env_file: DHB_AX_ROOT_PASSWD is unset or empty" >&2
	echo "generate a hash with: openssl passwd -6" >&2
	exit 1
	;;
'$1$'* | '$5$'* | '$6$'*) ;;
*)
	# Buildroot treats anything without a crypt prefix as cleartext and
	# runs it through host-mkpasswd, which would work but puts the
	# password in the build log.  Refuse instead of quietly accepting a
	# weaker arrangement than the one this file documents.
	echo "$env_file: DHB_AX_ROOT_PASSWD is not a crypt hash" >&2
	echo "expected it to start with \$1\$, \$5\$ or \$6\$" >&2
	echo "generate one with: openssl passwd -6" >&2
	exit 1
	;;
esac

# The make-side $(shell) below reads the original hash from its environment.
# Sourcing local.env creates a shell variable but does not export it, so make
# would otherwise receive an empty value and silently generate root::.
export DHB_AX_ROOT_PASSWD

# The hash is handed over as a $(shell) call, because make interprets the $
# characters in a crypt hash as variable references and mangles it. Silent
# recipe output keeps the expanded hash out of the build log.
root_passwd_var='DHB_AX_ROOT_PASSWD=$(shell echo "$${DHB_AX_ROOT_PASSWD}")'

# Buildroot is mounted read-only, so every invocation is an out-of-tree build.
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output tree afterwards, but passing it every time is
# harmless and keeps the two calls identical.
br() {
	make --silent -C "$buildroot" O="$output" BR2_EXTERNAL="$external" \
		BR2_DL_DIR=/dl "$root_passwd_var" "$@"
}

check_root_password() {
	grep -qx 'BR2_TARGET_ENABLE_ROOT_LOGIN=y' "$output/.config" || return 0
	actual=$(sed -n 's/^root:\([^:]*\):.*/\1/p' "$output/target/etc/shadow")
	if [ "$actual" != "$DHB_AX_ROOT_PASSWD" ]; then
		echo "built root password does not match DHB_AX_ROOT_PASSWD" >&2
		return 1
	fi
	echo "root password verified: configured crypt hash installed"
}

# Buildroot does not remove an old filesystem image when its format is later
# disabled. Do not copy such stale outputs into artifacts/ where they can look
# like products of the current configuration.
prune_disabled_images() {
	if ! grep -qx 'BR2_TARGET_ROOTFS_CPIO=y' "$output/.config"; then
		rm -f "$output/images/rootfs.cpio" "$artifacts/rootfs.cpio"
	fi
	if ! grep -qx 'BR2_TARGET_ROOTFS_TAR=y' "$output/.config"; then
		rm -f "$output/images/rootfs.tar" "$artifacts/rootfs.tar"
	fi
}

# SDK archives belong only to the toolchain configuration. This also removes
# one left by an earlier `make sdk` in an image output tree.
prune_image_sdk() {
	[ "$build_config" = toolchain ] && return
	rm -f "$output"/images/*_sdk-buildroot.tar.gz \
		"$artifacts"/*_sdk-buildroot.tar.gz
}

# kconfig drops a defconfig line whose symbol does not exist, or whose
# dependencies are unmet, without printing anything at all.  That is how an
# entire toolchain selection went missing once: BR2_TOOLCHAIN_EXTERNAL_BOOTLIN
# depends on an x86_64 host, this container is aarch64, and the build simply
# fell back to the default toolchain.  Compare the two files and complain.
check_defconfig() {
	missing=
	while IFS= read -r line; do
		case $line in
		# "# BR2_FOO is not set" is an assertion, not prose: kconfig
		# writes it for a symbol that is off, and several of ours are
		# deliberately off because their default is on.  Check those
		# too, and skip only genuine comments.
		'# BR2_'*' is not set') : ;;
		'' | \#*) continue ;;
		esac
		grep -qxF "$line" "$output/.config" || missing="$missing$line
"
	done < "$defconfig_file"

	if [ -n "$missing" ]; then
		echo >&2
		echo "these defconfig settings did not survive into .config:" >&2
		echo "$missing" | sed -e '/^$/d' -e 's/^/  /' >&2
		echo >&2
		echo "the symbol does not exist, or its dependencies are unmet" >&2
		return 1
	fi
	echo "defconfig verified: every setting present in .config"
}

# Linux supports building against headers older than the running kernel, but
# not newer ones. Compare the declared series before spending time building.
check_headers_not_newer() {
	headers=$(sed -n \
		's/^BR2_TOOLCHAIN_EXTERNAL_HEADERS_\([0-9][0-9_]*\)=y$/\1/p' \
		"$defconfig_file" | tr _ .)
	kernel=$(sed -n \
		's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\([0-9][0-9.]*\)"$/\1/p' \
		"$defconfig_file")

	# A toolchain-only configuration has no kernel to compare.
	[ -n "$headers" ] && [ -n "$kernel" ] || return 0

	if awk -v headers="$headers" -v kernel="$kernel" 'BEGIN {
		split(headers, h, "."); split(kernel, k, ".");
		exit !((h[1] + 0 > k[1] + 0) ||
		       (h[1] + 0 == k[1] + 0 && h[2] + 0 > k[2] + 0));
	}'; then
		echo "toolchain headers $headers are newer than kernel $kernel" >&2
		echo "use headers no newer than the oldest kernel this image runs" >&2
		return 1
	fi

	echo "kernel headers verified: $headers is not newer than $kernel"
}

stage_sdk() {
	source=$output/images/$sdk_tarball
	if [ ! -f "$source" ]; then
		echo "Buildroot did not produce $source" >&2
		return 1
	fi

	temporary=/dl/.$sdk_tarball.$$
	install -m 0644 "$source" "$temporary"
	mv -f "$temporary" "/dl/$sdk_tarball"
	echo "staged SDK -> /dl/$sdk_tarball"
}

check_headers_not_newer
prune_image_sdk
built_all=0

if [ "$#" -gt 0 ]; then
	br "$@"
	case " $* " in
	*" $defconfig "*) check_defconfig ;;
	esac
	case " $* " in
	*" sdk "*)
		[ "$build_config" = toolchain ] && stage_sdk
		;;
	esac
else
	br "$defconfig"
	check_defconfig
	if [ "$build_config" = toolchain ]; then
		br -j"$(nproc)" sdk
		stage_sdk
	else
		br -j"$(nproc)" all
		built_all=1
	fi
fi

[ "$built_all" = 0 ] || check_root_password

prune_disabled_images

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
	sha256sum "$output"/images/*
fi
