#!/bin/sh
# macOS wrapper around the containerised build.
#
#   build.sh [minimal|ethernet]
#
# The patch queue is applied to KERNEL_SRC in place.  Repeat builds are fine,
# because each patch is skipped when it already reverse-applies -- but a tree
# carrying a *superseded* revision of the queue cannot be repaired that way.
# Run scripts/bootstrap-sources.sh for a known-good tree.
set -eu

variant=${1:-ethernet}
workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
kernel_src=${KERNEL_SRC:-$workspace/kernel/linux-6.18.42-build}

if [ ! -f "$kernel_src/Makefile" ]; then
	echo "no kernel source at $kernel_src" >&2
	echo "run kernel-port/scripts/bootstrap-sources.sh first" >&2
	exit 1
fi

docker build -t dhb-ax-kernel-builder:bookworm "$workspace/kernel-port"
docker run --rm \
	-v "$kernel_src:/src" \
	-v "$workspace:/work" \
	dhb-ax-kernel-builder:bookworm \
	/work/kernel-port/scripts/build-in-container.sh "$variant"
