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

systemctl --root="$rootfs" enable \
	ssh nftables systemd-networkd systemd-resolved systemd-timesyncd >/dev/null

install -d -m 0755 "$output"
chroot "$rootfs" dpkg-query -W -f='${binary:Package}\t${Version}\n' |
	LC_ALL=C sort > "$output/.packages.txt.$$"

archive=$output/.rootfs.tar.$$
tar --sort=name --numeric-owner --acls --xattrs --xattrs-include='*' \
	--format=posix --pax-option=delete=atime,delete=ctime \
	-C "$rootfs" -cf "$archive" .
chmod 0644 "$archive"
mv -f "$archive" "$output/rootfs.tar"
mv -f "$output/.packages.txt.$$" "$output/packages.txt"
rm -f "$output/rootfs.tar.sha256"

{
	echo 'suite=trixie'
	echo 'architecture=armhf'
	echo "builder_base=${DHB_AX_DEBIAN_BUILDER_BASE:-unknown}"
	echo "mmdebstrap=$(mmdebstrap --version | head -n 1)"
	echo "kernel_release=$kernel_release"
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$output/.build-info.txt.$$"
mv -f "$output/.build-info.txt.$$" "$output/build-info.txt"

echo "Debian rootfs artifacts -> ${output#/work/}/"
