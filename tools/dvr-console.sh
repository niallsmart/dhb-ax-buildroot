#!/bin/sh
# Attach to the persistent DVR UART console, starting it when necessary.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"

require_env_file "$repo/local.env" DHB_AX_PI_IPADDR

if ! tmux has-session -t dvr 2>/dev/null; then
	tmux start-server \; set-option -g history-limit 100000 \; \
		new-session -d -s dvr \
		"ssh -tt $DHB_AX_PI_IPADDR 'picocom -b 115200 --omap crcrlf /dev/serial0'"
fi

if [ -n "${TMUX:-}" ]; then
	exec tmux switch-client -t dvr
fi

exec tmux attach-session -t dvr
