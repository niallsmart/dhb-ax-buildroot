#!/bin/sh
# Publish the Buildroot root filesystem to the Raspberry Pi's NFS export.
#
# Full publications are deliberately refused while the DVR has an active NFS
# connection. Boot the small rescue image first. This prevents replacing or
# deleting programs underneath a live NFS-root system. For ordinary driver or
# configuration iteration, edit/copy the specific file through the mounted
# export instead of republishing the entire root.
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive=${1:-$repo/artifacts/buildroot/rootfs.tar}
host=${PI_HOST:-raspberrypi}
base=${NFS_BASE:-/srv/dhb-ax}
remote_archive=/tmp/dhb-ax-rootfs.tar

case $host in
	'' | [!A-Za-z0-9]* | *[!A-Za-z0-9_.@-]*)
		echo "publish-nfs-root: refusing unsafe Pi host: $host" >&2
		exit 2
		;;
esac
case $base in
	/srv/*) ;;
	*)
		echo "publish-nfs-root: refusing unsafe NFS base: $base" >&2
		exit 2
		;;
esac
case $base in
	*/../* | */.. | */./* | */. | *//*)
		echo "publish-nfs-root: refusing non-canonical NFS base: $base" >&2
		exit 2
		;;
	*[!A-Za-z0-9_./-]*)
		echo "publish-nfs-root: unsupported character in NFS base: $base" >&2
		exit 2
		;;
esac

if [ ! -f "$archive" ]; then
	echo "publish-nfs-root: no rootfs archive at $archive" >&2
	echo "build it first with: scripts/buildroot.sh" >&2
	exit 2
fi

echo "Publishing $(basename "$archive") to $host:$base/rootfs"
rsync --archive --checksum --progress -- "$archive" "$host:$remote_archive"

ssh -o BatchMode=yes "$host" sudo sh -s -- "$base" "$remote_archive" <<'REMOTE'
set -eu

base=$1
archive=$2
incoming=$base/.rootfs.incoming
current=$base/rootfs

# The export has historically allowed both addresses below for the DVR. An
# established NFS/TCP session from either means a full-root replacement is not
# safe. ss can prefix IPv4 peers with ::ffff:, so match the address anywhere.
if ss -Htn state established '( sport = :2049 )' 2>/dev/null |
	grep -Eq '192\.168\.(4\.77|7\.240):[0-9]+'; then
	echo "publish-nfs-root: DVR has an active NFS session" >&2
	echo "boot the rescue uImage before publishing a complete rootfs" >&2
	exit 3
fi

test -f "$archive"
mkdir -p "$base"

# No client is using this export, so the fixed staging name is safe to
# reclaim. Extraction happens beside the live name so a failure there leaves
# the current root untouched.
rm -rf -- "$incoming"
mkdir -m 0755 "$incoming"
tar --numeric-owner -xpf "$archive" -C "$incoming"

test -f "$incoming/bin/busybox"
test -L "$incoming/sbin/init"
test -f "$incoming/usr/sbin/sshd"
test -f "$incoming/etc/ssh/ssh_host_ed25519_key"
test -f "$incoming/root/.ssh/authorized_keys"
test "$(stat -c %a "$incoming/etc/ssh/ssh_host_ed25519_key")" = 600
test "$(stat -c %a "$incoming/root/.ssh/authorized_keys")" = 600

rm -rf -- "$current"
mv "$incoming" "$current"

rm -f -- "$archive"
sync
echo "publish-nfs-root: promoted $current"
REMOTE

echo "NFS root published successfully."
