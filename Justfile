# List available recipes.
default:
    @just --list

# Fetch and extract the pinned kernel and Buildroot sources.
bootstrap:
    scripts/bootstrap-sources.sh

# Build the kernel and rootfs; extra args pass through to buildroot.sh, e.g. `just build menuconfig`.
build *args:
    scripts/buildroot.sh {{args}}

# Build the Debian Trixie armhf root filesystem with the production modules.
debian:
    scripts/mmdebstrap.sh

# Drop the Buildroot output and download volumes.
clean:
    scripts/buildroot.sh --clean

# Attach to the persistent UART console, starting it if it isn't already running.
dvr-console:
    tools/dvr-console.sh

# Boot a named DVR profile; defaults to the installed USB/HDD system.
boot profile="buildroot-usb-hdd" *args:
    tools/dvr-boot.sh {{args}} {{profile}}

# Stage the artifacts for a named DVR profile; defaults to the USB/HDD system.
stage profile="buildroot-usb-hdd" *args:
    tools/dvr-stage.sh {{args}} {{profile}}

# Destructively repartition the HDD and USB drive; requires the minimal initramfs.
prepare-storage *args:
    tools/dvr-prepare-storage.sh {{args}}
