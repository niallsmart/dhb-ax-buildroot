#!/bin/sh
# Stage the kernel and root filesystem described by a DVR boot profile.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"

require_env_file "$repo/local.env" \
	DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR DHB_AX_DVR_NETMASK \
	DHB_AX_DVR_ETHADDR DHB_AX_ROOT_PASSWD
export DVR_BOOT_REPO_ROOT="$repo"

exec uv run --script "$repo/tools/dvr_stage.py" "$@"
