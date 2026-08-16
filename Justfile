# List available recipes.
default:
    @just --list

# Fetch and extract the pinned kernel and Buildroot sources.
bootstrap:
    scripts/bootstrap-sources.sh

# Build the kernel and rootfs; extra args pass through to buildroot.sh, e.g. `just build menuconfig`.
build *args:
    scripts/buildroot.sh {{args}}

# Drop the Buildroot output and download volumes.
clean:
    scripts/buildroot.sh --clean

# Attach to the persistent UART console, starting it if it isn't already running.
dvr-console:
    #!/bin/sh
    set -eu
    . scripts/lib.sh
    require_env_file local.env DHB_AX_PI_IPADDR
    if ! tmux has-session -t dvr 2>/dev/null; then
        tmux start-server \; set-option -g history-limit 100000 \; \
            new-session -d -s dvr "ssh -tt $DHB_AX_PI_IPADDR 'picocom -b 115200 --omap crcrlf /dev/serial0'"
    fi
    exec tmux attach-session -t dvr

# Run one command at the DVR's Linux shell over the serial console, e.g. `just exec 'cat /proc/mtd'`.
exec cmd:
    tools/dvr-console-exec.sh "{{cmd}}"

# Boot the installed USB kernel; extra args pass through to dvr-boot.sh, e.g. `just boot-usb --root nfs`.
boot-usb *args:
    tools/dvr-boot.sh usb {{args}}

# Stage the current build to the Pi and boot it over TFTP; extra args pass through to dvr-boot.sh.
boot-tftp *args:
    tools/dvr-boot.sh tftp {{args}}

# Destructively repartition the HDD and USB drive; requires the DVR to already be running from NFS root.
prepare-storage *args:
    tools/dvr-prepare-storage.sh {{args}}

# Install the current build -- rootfs to HDD, kernel to USB; extra args pass through, e.g. `just install --kernel-only`.
install *args:
    tools/dvr-install-system.sh {{args}}

# Publish the current build's rootfs to the Pi's NFS export, for NFS-root development, provisioning or recovery.
publish-nfs:
    scripts/publish-nfs-root.sh
