#!/bin/sh
# Drive Buildroot from inside the container.  Called by scripts/buildroot.sh.
#
#   buildroot-in-container.sh [target ...]
#
# With no target: configure from the defconfig if the output tree has no
# .config yet, then build everything.
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
# Deliberately *not* kernel-port/build/artifacts.  Both builds produce a
# zImage, and while the two paths coexist an image from one landing beside an
# image from the other is a trap.  Stage 5 compares them; Stage 6 makes this
# the only one.  The parent is already gitignored.
artifacts=/work/kernel-port/build/buildroot-artifacts

test -f "$buildroot/Makefile"
test -f "$external/external.desc"
mkdir -p "$output" /dl "$artifacts"

# Buildroot is mounted read-only, so every invocation is an out-of-tree build.
# BR2_EXTERNAL only has to be passed when the configuration is created; it is
# recorded in the output tree afterwards, but passing it every time is
# harmless and keeps the two calls identical.
br() {
	make -C "$buildroot" O="$output" BR2_EXTERNAL="$external" \
		BR2_DL_DIR=/dl "$@"
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
	if [ ! -f "$output/.config" ]; then
		br dhb_ax_defconfig
		check_defconfig
	fi
	br -j"$(nproc)" all
fi

# Copy out whatever the build produced.  A configure-only invocation leaves
# the images directory empty, which is not an error.
if [ -d "$output/images" ] && [ -n "$(ls -A "$output/images" 2>/dev/null)" ]; then
	echo
	echo "artifacts -> kernel-port/build/buildroot-artifacts/"
	for f in "$output"/images/*; do
		[ -f "$f" ] || continue
		install -m 0644 "$f" "$artifacts/"
		printf '  %s\n' "$(basename "$f")"
	done
	sha256sum "$output"/images/*
fi
