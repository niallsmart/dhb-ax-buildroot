#!/bin/sh
# Build the Debian armhf root filesystem in a native-architecture container.
set -eu

workspace=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$workspace/scripts/lib.sh"

require_env_file "$workspace/local.env" \
	DHB_AX_ROOT_PASSWD DHB_AX_DVR_ETHADDR

modules=$workspace/artifacts/buildroot/kernel-modules.tar
if [ ! -r "$modules" ]; then
	echo "no production kernel module archive at $modules" >&2
	echo "build it first with: scripts/buildroot.sh --config main" >&2
	exit 1
fi

local_ssh=$workspace/artifacts/local/ssh
for file in \
	authorized_keys \
	dropbear_ecdsa_host_key dropbear_ed25519_host_key dropbear_rsa_host_key \
	ssh_host_ecdsa_key ssh_host_ecdsa_key.pub \
	ssh_host_ed25519_key ssh_host_ed25519_key.pub \
	ssh_host_rsa_key ssh_host_rsa_key.pub; do
	if [ ! -r "$local_ssh/$file" ]; then
		echo "missing local SSH input: $local_ssh/$file" >&2
		exit 1
	fi
done

builder=dhb-ax-debian-rootfs:trixie-armhf
builder_base=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

docker build \
	--platform linux/arm/v7 \
	--file "$workspace/scripts/Dockerfile.debian-rootfs" \
	--tag "$builder" \
	"$workspace/scripts"

mkdir -p "$workspace/artifacts/debian"
docker run --rm \
	--platform linux/arm/v7 \
	--env DHB_AX_ROOT_PASSWD \
	--env DHB_AX_DVR_ETHADDR \
	--env "DHB_AX_DEBIAN_BUILDER_BASE=$builder_base" \
	--mount "type=bind,source=$workspace,target=/work,readonly" \
	--mount "type=bind,source=$workspace/artifacts,target=/work/artifacts" \
	"$builder" /work/artifacts/debian
