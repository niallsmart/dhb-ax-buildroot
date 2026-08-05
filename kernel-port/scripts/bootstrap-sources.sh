#!/bin/sh
# Recreate the source trees this port builds against.
#
#   bootstrap-sources.sh [--reset-build]
#
# Everything here is reproducible from two pinned inputs, so none of it needs
# backing up:
#
#   kernel/linux-6.18.42.tar.xz      official upstream tarball
#   vendor/openipc-linux-3.0.8/      vendor 3.0.8 tree at a pinned commit
#
# and two derived trees:
#
#   kernel/linux-6.18.42-pristine/   never modified; the reference the patch
#                                    queue is diffed against
#   kernel/linux-6.18.42-build/      pristine + the patch queue; what
#                                    build.sh compiles
#
# and, for the Buildroot path:
#
#   buildroot/buildroot-2026.02.3/   extracted from a checksum-pinned tarball
#
# --reset-build discards the build tree and re-derives it from pristine, which
# is the cure for a tree carrying a superseded revision of the patch queue.
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
kernel_dir=$workspace/kernel
vendor_dir=$workspace/vendor
buildroot_dir=$workspace/buildroot

version=6.18.42
tarball=$kernel_dir/linux-$version.tar.xz
tarball_url=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$version.tar.xz
pristine=$kernel_dir/linux-$version-pristine
build=$kernel_dir/linux-$version-build

vendor_repo=https://github.com/OpenIPC/linux.git
vendor_commit=a3bfde54cdcf641cc061206f5d2ba6e9ddbad324
vendor=$vendor_dir/openipc-linux-3.0.8

# 2026.02 is the LTS line, which suits a project picked up intermittently.
# The checksum is the one in the release's PGP-signed manifest at
# https://buildroot.org/downloads/buildroot-2026.02.3.tar.xz.sign
br_version=2026.02.3
br_tarball=$buildroot_dir/buildroot-$br_version.tar.xz
br_tarball_url=https://buildroot.org/downloads/buildroot-$br_version.tar.xz
br_sha256=5a59e7501b0b4ec52c41f4bfa79412320e0b37eae5f719605a258e8d0c6fc7fb
br_src=$buildroot_dir/buildroot-$br_version

reset_build=no
[ "${1:-}" = "--reset-build" ] && reset_build=yes

mkdir -p "$kernel_dir" "$vendor_dir" "$buildroot_dir"

if [ ! -f "$tarball" ]; then
	echo "fetching $tarball_url"
	curl --fail --location "$tarball_url" --output "$tarball"
fi

if [ ! -f "$pristine/Makefile" ]; then
	echo "extracting pristine tree"
	rm -rf "$pristine"
	mkdir -p "$pristine"
	tar -xJf "$tarball" -C "$pristine" --strip-components=1
fi

if [ "$reset_build" = yes ]; then
	echo "discarding build tree"
	rm -rf "$build"
fi

if [ ! -f "$build/Makefile" ]; then
	echo "deriving build tree from pristine"
	rm -rf "$build"
	# -c asks APFS for a copy-on-write clone: near-instant, and it costs no
	# extra disk until the patch queue modifies a file.  Fall back to a plain
	# recursive copy on filesystems that cannot do it.
	cp -Rc "$pristine" "$build" 2>/dev/null || cp -R "$pristine" "$build"
fi

if [ ! -d "$vendor/.git" ]; then
	echo "cloning vendor tree at $vendor_commit"
	rm -rf "$vendor"
	mkdir -p "$vendor"
	git -C "$vendor" init -q .
	git -C "$vendor" remote add origin "$vendor_repo"
	git -C "$vendor" fetch -q --depth 1 origin "$vendor_commit"
	git -C "$vendor" checkout -q FETCH_HEAD
fi

if [ ! -f "$br_tarball" ]; then
	echo "fetching $br_tarball_url"
	curl --fail --location "$br_tarball_url" --output "$br_tarball"
fi

# The tarball is unpacked into a tree the build then treats as read-only, so
# verify it once here rather than trusting whatever is on disk.
if command -v sha256sum >/dev/null 2>&1; then
	got=$(sha256sum "$br_tarball" | cut -d' ' -f1)
else
	got=$(shasum -a 256 "$br_tarball" | cut -d' ' -f1)
fi
if [ "$got" != "$br_sha256" ]; then
	echo "checksum mismatch for $br_tarball" >&2
	echo "  expected $br_sha256" >&2
	echo "  got      $got" >&2
	echo "delete the file and re-run to fetch it again" >&2
	exit 1
fi

if [ ! -f "$br_src/Makefile" ]; then
	echo "extracting Buildroot $br_version"
	rm -rf "$br_src"
	tar -xJf "$br_tarball" -C "$buildroot_dir"
fi

echo
echo "ready:"
printf '  %-34s %s\n' "kernel source (build)" "$build"
printf '  %-34s %s\n' "kernel source (patch reference)" "$pristine"
printf '  %-34s %s\n' "vendor 3.0.8 reference" "$vendor"
printf '  %-34s %s\n' "buildroot $br_version" "$br_src"
