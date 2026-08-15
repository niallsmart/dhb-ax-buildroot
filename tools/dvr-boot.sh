#!/bin/sh
# Reliably boot a kernel on the DVR through the Raspberry Pi UART.
#
# The usb subcommand loads an existing image from the USB FAT filesystem.
# The tftp subcommand stages a local image to the Pi first. Neither saves
# the U-Boot environment or writes board storage.
#
# This wrapper resolves local.env, then hands option parsing and the boot
# sequence itself to tools/dvr-boot.exp.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"

require_env_file "$repo/local.env" \
	DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR DHB_AX_DVR_NETMASK DHB_AX_DVR_ETHADDR
export DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR DHB_AX_DVR_NETMASK DHB_AX_DVR_ETHADDR
export DVR_BOOT_REPO_ROOT="$repo"

exec expect -f "$repo/tools/dvr-boot.exp" "$@"
