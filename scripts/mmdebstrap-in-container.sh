#!/bin/sh
# Construct the canonical Debian armhf rootfs with mmdebstrap. This runs inside linux/arm/v7.
set -eu
umask 022

output=${1:-/work/artifacts/debian}
workspace=/work
modules=$workspace/artifacts/buildroot/kernel-modules.tar
local_ssh=$workspace/artifacts/local/ssh
overlay=$workspace/br2-external/board/dhb-ax/debian-rootfs-overlay
package_list=$workspace/scripts/debian-packages.txt
rootfs=$(mktemp -d /tmp/dhb-ax-debian-rootfs.XXXXXX)

cleanup()
{
	rm -rf -- "$rootfs"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail()
{
	echo "mmdebstrap: $*" >&2
	exit 1
}

[ "$(uname -m)" = armv7l ] || fail "builder is not running as linux/arm/v7"
[ -r "$modules" ] || fail "kernel module archive is missing"

kernel_release=$(tar -tf "$modules" |
	sed -n 's#^lib/modules/\([^/][^/]*\)/$#\1#p' | sort -u)

packages=$(paste -sd, "$package_list")

mmdebstrap \
	--architectures=armhf \
	--variant=minbase \
	--components=main \
	--include="$packages" \
	--aptopt='APT::Install-Recommends "false";' \
	--aptopt='APT::Install-Suggests "false";' \
	trixie "$rootfs"

cp -a --no-preserve=ownership "$overlay/." "$rootfs/"
sed -i "s/@DHB_AX_DVR_ETHADDR@/$DHB_AX_DVR_ETHADDR/" \
	"$rootfs/etc/systemd/network/10-dhb-ax.link"
ln -snf /usr/share/zoneinfo/America/New_York "$rootfs/etc/localtime"
ln -snf /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"
printf 'root:%s\n' "$DHB_AX_ROOT_PASSWD" | chroot "$rootfs" chpasswd

install -d -m 0700 "$rootfs/root/.ssh"
install -m 0600 "$local_ssh/authorized_keys" \
	"$rootfs/root/.ssh/authorized_keys"
install -d -m 0755 "$rootfs/etc/ssh"
for kind in ed25519 ecdsa rsa; do
	install -m 0600 "$local_ssh/ssh_host_${kind}_key" \
		"$rootfs/etc/ssh/ssh_host_${kind}_key"
	install -m 0644 "$local_ssh/ssh_host_${kind}_key.pub" \
		"$rootfs/etc/ssh/ssh_host_${kind}_key.pub"
done

install -d -m 0755 "$rootfs/srv/data"

tar --numeric-owner -xpf "$modules" -C "$rootfs"
chroot "$rootfs" depmod "$kernel_release"

# fstrim.timer runs weekly against everything mounted, which is what keeps the
# SSD's free blocks known to the drive. util-linux's postinst already enables
# it; naming it here states that the image depends on it, so a change to that
# default is caught rather than silently dropping TRIM.
systemctl --root="$rootfs" enable \
	ssh nftables systemd-networkd systemd-resolved systemd-timesyncd \
	fstrim.timer >/dev/null

install -d -m 0755 "$output"
chroot "$rootfs" dpkg-query -W -f='${binary:Package}\t${Version}\n' |
	LC_ALL=C sort > "$output/packages.txt"

# systemd opens /dev/console before it mounts devtmpfs, and this archive is
# unpacked into an empty ramfs when it serves as the initramfs root. Debian
# leaves no device nodes behind, so the node has to be here.
[ -c "$rootfs/dev/console" ] || mknod -m 0600 "$rootfs/dev/console" c 5 1

# newc, gzipped: U-Boot loads this to RAM as the initramfs root, and
# tools/dvr-stage.sh streams the same archive onto the HDD partition. newc
# carries no extended attributes or ACLs; no package installed here sets either.
(cd "$rootfs" && find . -print0 |
	LC_ALL=C sort -z |
	cpio --null --create --format=newc --quiet) |
	gzip -9 > "$output/rootfs.cpio.gz"

{
	echo 'suite=trixie'
	echo 'architecture=armhf'
	echo "builder_base=${DHB_AX_DEBIAN_BUILDER_BASE:-unknown}"
	echo "mmdebstrap=$(mmdebstrap --version | head -n 1)"
	echo "kernel_release=$kernel_release"
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$output/build-info.txt"

rm -f "$output/rootfs.tar" "$output/rootfs.tar.sha256"

echo "Debian rootfs artifacts -> ${output#/work/}/"
