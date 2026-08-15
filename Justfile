
dvr:
    #!/bin/sh
    set -eu
    . scripts/lib.sh
    require_env_file local.env DHB_AX_PI_IPADDR
    if ! tmux has-session -t dvr 2>/dev/null; then
        tmux start-server \; set-option -g history-limit 100000 \; \
            new-session -d -s dvr "ssh -tt $DHB_AX_PI_IPADDR 'picocom -b 115200 --omap crcrlf /dev/serial0'"
    fi
    exec tmux attach-session -t dvr
