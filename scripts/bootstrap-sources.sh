#!/bin/sh
# Recreate the Buildroot source tree this port builds against.
#
#   bootstrap-sources.sh
#
# Everything here is reproducible from the checksum-pinned Buildroot tarball,
# so none of it needs backing up. scripts/kernel-sources creates the ignored
# kernel workspace from a shared Git clone and the checked-in patch queue.
#
# Buildroot extracts and patches its own copy of the kernel on every build, so
# there is no persistent build tree here any more and no --reset-build.  The
# whole class of "tree carrying a superseded patch" problem went with it.
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
buildroot_dir=$workspace/buildroot

# 2026.02 is the LTS line, which suits a project picked up intermittently.
# The checksum is the one in the release's PGP-signed manifest at
# https://buildroot.org/downloads/buildroot-2026.02.3.tar.xz.sign
br_version=2026.02.3
br_tarball=$buildroot_dir/buildroot-$br_version.tar.xz
br_tarball_url=https://buildroot.org/downloads/buildroot-$br_version.tar.xz
br_sha256=5a59e7501b0b4ec52c41f4bfa79412320e0b37eae5f719605a258e8d0c6fc7fb
br_src=$buildroot_dir/buildroot-$br_version

mkdir -p "$buildroot_dir"

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
printf '  %-34s %s\n' "buildroot $br_version" "$br_src"
