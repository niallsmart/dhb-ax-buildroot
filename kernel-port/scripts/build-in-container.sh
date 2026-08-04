#!/bin/sh
# Build one DHB-AX kernel variant.  Runs inside the Debian cross-build image.
#
#   build-in-container.sh [minimal|ethernet]
#
set -eu

variant=${1:-ethernet}
kernel_src=${KERNEL_SRC:-/src}
port_dir=${PORT_DIR:-/work/kernel-port}
# Build in the container's own filesystem.  A kernel build writes tens of
# thousands of small files, which is slow through a bind-mounted host
# directory; only the finished artifacts are copied back.
build_root=${BUILD_ROOT:-/build}

case $variant in
minimal)
	dts=hi3531-dhb-ax
	config=dhb_ax_minimal.config
	init=init
	applets="cat cttyhack dmesg ls mount setsid sh uname"
	image_name='Linux-6.18.42 DHB-AX RAM bring-up'
	suffix=
	;;
ethernet)
	dts=hi3531-dhb-ax-ethernet
	config=dhb_ax_ethernet.config
	init=init-ethernet
	applets="cat cttyhack devmem df dmesg find grep head hostname
		 ifconfig insmod ip ls lsmod md5sum mkdir modprobe mount od
		 ping readlink reboot rmmod setsid sh sleep sync tail tftp
		 umount uname"
	image_name='Linux-6.18.42 DHB-AX Ethernet'
	suffix=-ethernet
	;;
*)
	echo "unknown variant: $variant (expected minimal or ethernet)" >&2
	exit 2
	;;
esac

test -f "$kernel_src/Makefile"

output_dir=$build_root/$variant
initramfs_dir=$build_root/initramfs-$variant
artifacts=$port_dir/build/artifacts
dts_dir=arch/arm/boot/dts/hisilicon
stmmac_dir=drivers/net/ethernet/stmicro/stmmac

rm -rf "$initramfs_dir"
mkdir -p "$output_dir" "$artifacts" \
	 "$initramfs_dir/bin" "$initramfs_dir/dev" "$initramfs_dir/proc" \
	 "$initramfs_dir/sys" "$initramfs_dir/tmp" "$initramfs_dir/sbin"

install -m 0755 /opt/armhf-busybox/bin/busybox "$initramfs_dir/bin/busybox"
install -m 0755 "$port_dir/initramfs/$init" "$initramfs_dir/init"
for applet in $applets; do
	ln -sfn busybox "$initramfs_dir/bin/$applet"
done

# The kernel runs /sbin/modprobe for request_module(), which is how vfat pulls
# in its NLS codepage.  Without this the mount fails with EINVAL and nothing
# is logged, because the failure happens before the filesystem driver starts.
ln -sfn ../bin/busybox "$initramfs_dir/sbin/modprobe"

# Both device trees and the glue driver are installed for either variant;
# the Kconfig seed decides what is actually built into the image.
install -m 0644 "$port_dir/dts/hi3531-dhb-ax.dtsi" "$kernel_src/$dts_dir/"
install -m 0644 "$port_dir/dts/hi3531-dhb-ax.dts" "$kernel_src/$dts_dir/"
install -m 0644 "$port_dir/dts/hi3531-dhb-ax-ethernet.dts" "$kernel_src/$dts_dir/"
install -m 0644 "$port_dir/drivers/dwmac-hi3531.c" "$kernel_src/$stmmac_dir/"
install -m 0644 "$port_dir/drivers/ahci_hi3531.c" "$kernel_src/drivers/ata/"
install -m 0644 "$port_dir/drivers/phy-hi3531-usb.c" "$kernel_src/drivers/phy/hisilicon/"

# Apply the queue in order.  A patch that reverse-applies cleanly is already
# in the tree, which keeps repeat builds against the same source working.
for p in "$port_dir"/patches/*.patch; do
	if patch --batch --dry-run --reverse --force -d "$kernel_src" -p1 \
		< "$p" >/dev/null 2>&1; then
		echo "already applied: $(basename "$p")"
	else
		echo "applying: $(basename "$p")"
		patch --batch --forward -d "$kernel_src" -p1 < "$p"
	fi
done

make -C "$kernel_src" O="$output_dir" ARCH=arm \
	KCONFIG_ALLCONFIG="$port_dir/configs/$config" allnoconfig
"$kernel_src/scripts/config" --file "$output_dir/.config" \
	--set-str INITRAMFS_SOURCE "$initramfs_dir"
make -C "$kernel_src" O="$output_dir" ARCH=arm \
	CROSS_COMPILE=arm-linux-gnueabihf- olddefconfig

make -C "$kernel_src" O="$output_dir" ARCH=arm \
	CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)" zImage dtbs

# Loadable modules are the fast path for driver bring-up: rebuild one .ko,
# push it to the running board and insmod, instead of reflashing a kernel.
if grep -q '^CONFIG_MODULES=y' "$output_dir/.config"; then
	mod_stage=$build_root/modules-$variant
	rm -rf "$mod_stage"
	make -C "$kernel_src" O="$output_dir" ARCH=arm \
		CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)" modules
	make -C "$kernel_src" O="$output_dir" ARCH=arm \
		CROSS_COMPILE=arm-linux-gnueabihf- \
		INSTALL_MOD_PATH="$mod_stage" modules_install
	tar -C "$mod_stage" -czf \
		"$artifacts/modules-6.18.42-dhb-ax$suffix.tar.gz" lib
	echo "modules packaged:"
	find "$mod_stage" -name '*.ko*' -printf '  %P\n' | head -20
fi

zimage=$artifacts/zImage-6.18.42-dhb-ax$suffix
dtb=$artifacts/$dts.dtb
appended=$zimage-appended-dtb
uimage=$artifacts/uImage-6.18.42-dhb-ax$suffix

install -m 0644 "$output_dir/arch/arm/boot/zImage" "$zimage"
install -m 0644 "$output_dir/$dts_dir/$dts.dtb" "$dtb"
install -m 0644 "$output_dir/.config" "$artifacts/config-6.18.42-dhb-ax$suffix"
install -m 0644 "$output_dir/System.map" \
	"$artifacts/System.map-6.18.42-dhb-ax$suffix"

# The old U-Boot passes ATAGs and has no FDT commands, so the DTB rides
# appended to the zImage.
cat "$zimage" "$dtb" > "$appended"

mkimage -A arm -O linux -T kernel -C none \
	-a 0x80008000 -e 0x80008000 \
	-n "$image_name" \
	-d "$appended" \
	"$uimage"

file "$zimage" "$appended" "$uimage"
mkimage -l "$uimage"
sha256sum "$zimage" "$appended" "$uimage" "$dtb"
