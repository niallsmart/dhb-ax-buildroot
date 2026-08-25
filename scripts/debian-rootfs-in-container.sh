#!/bin/sh
# Construct the canonical Debian armhf rootfs. This runs inside linux/arm/v7.
set -eu
umask 022

output=${1:-/work/artifacts/debian}
workspace=/work
modules=$workspace/artifacts/buildroot/kernel-modules.tar
local_ssh=$workspace/artifacts/local/ssh
rootfs=$(mktemp -d /tmp/dhb-ax-debian-rootfs.XXXXXX)

cleanup()
{
	rm -rf -- "$rootfs"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

fail()
{
	echo "debian-rootfs: $*" >&2
	exit 1
}

[ "$(uname -m)" = armv7l ] || fail "builder is not running as linux/arm/v7"
[ -n "${DHB_AX_ROOT_PASSWD:-}" ] || fail "DHB_AX_ROOT_PASSWD is empty"
case $DHB_AX_ROOT_PASSWD in
*'
'*) fail "DHB_AX_ROOT_PASSWD contains a newline" ;;
esac
[ -n "${DHB_AX_DVR_ETHADDR:-}" ] || fail "DHB_AX_DVR_ETHADDR is empty"
[ -r "$modules" ] || fail "kernel module archive is missing"

expected_release=$(sed -n \
	's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\([0-9][0-9.]*\)"$/\1/p' \
	"$workspace/br2-external/configs/dhb_ax_defconfig")
releases=$(tar -tf "$modules" |
	sed -n 's#^lib/modules/\([^/][^/]*\)/$#\1#p' | sort -u)
set -- $releases
[ "$#" -eq 1 ] || fail "module archive must contain exactly one release"
kernel_release=$1
[ "$kernel_release" = "$expected_release" ] ||
	fail "module release $kernel_release does not match kernel $expected_release"

fingerprint()
{
	ssh-keygen -lf /dev/stdin -E sha256 | awk '{ print $2 }'
}

for kind in ed25519 ecdsa rsa; do
	open_private=$local_ssh/ssh_host_${kind}_key
	open_public=$open_private.pub
	dropbear_private=$local_ssh/dropbear_${kind}_host_key
	for file in "$open_private" "$open_public" "$dropbear_private"; do
		[ -r "$file" ] || fail "missing SSH identity input: $file"
	done

	open_fingerprint=$(ssh-keygen -y -f "$open_private" | fingerprint)
	public_fingerprint=$(fingerprint < "$open_public")
	dropbear_fingerprint=$(dropbearkey -y -f "$dropbear_private" 2>/dev/null |
		sed -n '/^ssh-/p; /^ecdsa-/p' | fingerprint)
	[ -n "$open_fingerprint" ] || fail "could not read OpenSSH $kind key"
	[ "$open_fingerprint" = "$public_fingerprint" ] ||
		fail "OpenSSH $kind private and public keys diverge"
	[ "$open_fingerprint" = "$dropbear_fingerprint" ] ||
		fail "OpenSSH and Dropbear $kind host keys diverge"
done

packages='systemd-sysv,udev,dbus,systemd-resolved,systemd-timesyncd,openssh-server,ca-certificates,nftables,kmod,e2fsprogs,dosfstools,util-linux,smartmontools,iproute2,ethtool,procps,psmisc,lsof,curl,rsync,less,vim-tiny'
mirrors='deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://security.debian.org/debian-security trixie-security main'

mmdebstrap \
	--architectures=armhf \
	--variant=minbase \
	--components=main \
	--include="$packages" \
	--aptopt='APT::Install-Recommends "false";' \
	--aptopt='APT::Install-Suggests "false";' \
	trixie "$rootfs" "$mirrors"

printf 'dhb-ax-debian\n' > "$rootfs/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tdhb-ax-debian\n' > "$rootfs/etc/hosts"
ln -snf /usr/share/zoneinfo/UTC "$rootfs/etc/localtime"
printf 'Etc/UTC\n' > "$rootfs/etc/timezone"
printf 'LANG=C.UTF-8\n' > "$rootfs/etc/default/locale"
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
cat > "$rootfs/etc/ssh/sshd_config.d/dhb-ax.conf" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

install -d -m 0755 "$rootfs/etc/systemd/network"
cat > "$rootfs/etc/systemd/network/10-dhb-ax.link" <<EOF
[Match]
OriginalName=eth*

[Link]
NamePolicy=
Name=eth0
MACAddressPolicy=none
MACAddress=$DHB_AX_DVR_ETHADDR
EOF
cat > "$rootfs/etc/systemd/network/20-eth0.network" <<'EOF'
[Match]
Name=eth0

[Link]
RequiredForOnline=no

[Network]
DHCP=yes
IPv6AcceptRA=yes
KeepConfiguration=static
EOF
ln -snf /run/systemd/resolve/stub-resolv.conf "$rootfs/etc/resolv.conf"

install -d -m 0755 "$rootfs/srv/data"
cat > "$rootfs/etc/fstab" <<'EOF'
# <file system>       <mount point> <type> <options>       <dump> <pass>
LABEL=dhb-ax-data     /srv/data     ext4   defaults,nofail 0      2
LABEL=dhb-ax-swap     none          swap   sw              0      0
EOF

install -d -m 0755 "$rootfs/etc/apt/preferences.d"
cat > "$rootfs/etc/apt/preferences.d/00-dhb-ax-kernel-boundary" <<'EOF'
Package: linux-image-* linux-headers-* linux-modules-* flash-kernel u-boot-* uboot-mkimage
Pin: version *
Pin-Priority: -1
EOF
cat > "$rootfs/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://security.debian.org/debian-security trixie-security main
EOF
rm -f "$rootfs/etc/apt/sources.list.d/debian.sources"

tar --numeric-owner -xpf "$modules" -C "$rootfs"
install -d -m 0755 "$rootfs/usr/lib/dhb-ax"
printf '%s\n' "$kernel_release" > "$rootfs/usr/lib/dhb-ax/kernel-release"
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

sha256sum "$output/rootfs.tar" |
	sed 's#  .*/#  #' > "$output/.rootfs.tar.sha256.$$"
mv -f "$output/.rootfs.tar.sha256.$$" "$output/rootfs.tar.sha256"

{
	echo 'suite=trixie'
	echo 'architecture=armhf'
	echo "builder_base=${DHB_AX_DEBIAN_BUILDER_BASE:-unknown}"
	echo "mmdebstrap=$(mmdebstrap --version | head -n 1)"
	echo "kernel_release=$kernel_release"
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$output/.build-info.txt.$$"
mv -f "$output/.build-info.txt.$$" "$output/build-info.txt"

sha256sum "$output/rootfs.tar"
echo "Debian rootfs artifacts -> ${output#/work/}/"
