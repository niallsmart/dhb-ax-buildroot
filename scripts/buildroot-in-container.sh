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
# only so it can take ownership of the two named volumes, which come up owned
# by root the first time they are created.  Everything after this runs as br.
if [ "$(id -u)" = 0 ]; then
	mkdir -p /output /dl
	for d in /output /dl; do
		[ "$(stat -c %u "$d")" = 1000 ] || chown -R br:br "$d"
	done
	exec setpriv --reuid=br --regid=br --init-groups \
		env HOME=/home/br LANG="${LANG:-C.UTF-8}" \
		LC_ALL="${LC_ALL:-C.UTF-8}" "$0" "$@"
fi

buildroot=${BUILDROOT:-/buildroot}
output=${BR_OUTPUT:-/output}
external=${BR2_EXTERNAL:-/work/br2-external}
# Keep finished images outside the Buildroot output volume so they are easy to
# stage and survive container recreation. The parent is gitignored.
artifacts=/work/artifacts/buildroot

test -f "$buildroot/Makefile"
test -f "$external/external.desc"
mkdir -p "$output" /dl "$artifacts"

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

# The defconfig refers to $(DHB_AX_ROOT_PASSWD); this supplies it.  The hash
# is handed over as a $(shell) call that re-reads local.env, not as the hash
# itself, because make expands the $ in a crypt hash as variable references
# and mangles it -- see the comment in configs/dhb_ax_defconfig.  $$ escapes
# the shell variable so make passes it through to /bin/sh untouched.
root_passwd_var='DHB_AX_ROOT_PASSWD=$(shell . '"$env_file"' && printf %s "$$DHB_AX_ROOT_PASSWD")'

# Buildroot is mounted read-only, so every invocation is an out-of-tree build.
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output tree afterwards, but passing it every time is
# harmless and keeps the two calls identical.
br() {
	make -C "$buildroot" O="$output" BR2_EXTERNAL="$external" \
		BR2_DL_DIR=/dl "$root_passwd_var" "$@"
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
	done < "$external/configs/dhb_ax_defconfig"

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

if [ "$#" -gt 0 ]; then
	br "$@"
	case " $* " in
	*" dhb_ax_defconfig "*) check_defconfig ;;
	esac
else
	br dhb_ax_defconfig
	check_defconfig
	br -j"$(nproc)" all
fi

prune_disabled_images

# Copy out whatever the build produced.  A configure-only invocation leaves
# the images directory empty, which is not an error.
if [ -d "$output/images" ] && [ -n "$(ls -A "$output/images" 2>/dev/null)" ]; then
	echo
	echo "artifacts -> artifacts/buildroot/"
	for f in "$output"/images/*; do
		[ -f "$f" ] || continue
		install -m 0644 "$f" "$artifacts/"
		printf '  %s\n' "$(basename "$f")"
	done
	sha256sum "$output"/images/*
fi
