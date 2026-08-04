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
# --reset-build discards the build tree and re-derives it from pristine, which
# is the cure for a tree carrying a superseded revision of the patch queue.
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
kernel_dir=$workspace/kernel
vendor_dir=$workspace/vendor

version=6.18.42
tarball=$kernel_dir/linux-$version.tar.xz
tarball_url=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$version.tar.xz
pristine=$kernel_dir/linux-$version-pristine
build=$kernel_dir/linux-$version-build

vendor_repo=https://github.com/OpenIPC/linux.git
vendor_commit=a3bfde54cdcf641cc061206f5d2ba6e9ddbad324
vendor=$vendor_dir/openipc-linux-3.0.8

reset_build=no
[ "${1:-}" = "--reset-build" ] && reset_build=yes

mkdir -p "$kernel_dir" "$vendor_dir"

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

echo
echo "ready:"
printf '  %-34s %s\n' "kernel source (build)" "$build"
printf '  %-34s %s\n' "kernel source (patch reference)" "$pristine"
printf '  %-34s %s\n' "vendor 3.0.8 reference" "$vendor"
