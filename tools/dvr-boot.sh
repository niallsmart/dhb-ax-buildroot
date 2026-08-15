#!/bin/sh
# Reliably boot a kernel on the DVR through the Raspberry Pi UART.
#
# By default the image argument is a filename beneath /srv/tftp on the Pi.
# With --stage, the tool first publishes a local image there. With --usb, it
# loads an existing image from the USB FAT filesystem. It never saves the
# U-Boot environment or writes board storage.
#
# This wrapper resolves local.env, then hands option parsing and the boot
# sequence itself to tools/dvr-boot.exp.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"

require_env_file "$repo/local.env" \
	DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR DHB_AX_DVR_NETMASK DHB_AX_DVR_ETHADDR
export DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR DHB_AX_DVR_NETMASK DHB_AX_DVR_ETHADDR

exec expect -f "$repo/tools/dvr-boot.exp" "$@"
