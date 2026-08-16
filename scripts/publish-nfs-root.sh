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
. "$repo/scripts/lib.sh"
require_env_file "$repo/local.env" DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR
require_ipaddr DHB_AX_PI_IPADDR DHB_AX_DVR_IPADDR

archive=${1:-$repo/artifacts/buildroot/rootfs.tar}
host=$DHB_AX_PI_IPADDR
base=${NFS_BASE:-/srv/dhb-ax}
remote_archive=/tmp/dhb-ax-rootfs.tar

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

# Checked before anything is transferred, so a live NFS session costs one
# quick round trip rather than a wasted upload.
ssh -o BatchMode=yes "$host" sudo sh -s -- "$DHB_AX_DVR_IPADDR" <<'GUARD'
set -eu

dvr_ipaddr=$1

# An established NFS/TCP session from the DVR means a full-root replacement
# is not safe. ss can prefix IPv4 peers with ::ffff:, so match the address
# anywhere rather than anchoring to the start of the peer field.
dvr_ipaddr_pattern=$(printf '%s\n' "$dvr_ipaddr" | sed 's/\./\\./g')
if ss -Htn state established '( sport = :2049 )' 2>/dev/null |
	grep -Eq "${dvr_ipaddr_pattern}:[0-9]+"; then
	echo "publish-nfs-root: DVR has an active NFS session" >&2
	echo "boot the rescue uImage before publishing a complete rootfs" >&2
	exit 3
fi
GUARD

echo "Publishing $(basename "$archive") to $host:$base/rootfs"
rsync --archive --checksum --progress -- "$archive" "$host:$remote_archive"

ssh -o BatchMode=yes "$host" sudo sh -s -- "$base" "$remote_archive" <<'REMOTE'
set -eu

base=$1
archive=$2
incoming=$base/.rootfs.incoming
current=$base/rootfs

mkdir -p "$base" "$current"
rm -rf -- "$incoming"
mkdir -m 0755 "$incoming"
tar --numeric-owner -xpf "$archive" -C "$incoming"

# The guard above already confirmed no client can be using $current, so
# mirroring straight onto it is safe: rsync only touches what changed.
rsync --archive --delete --numeric-ids -- "$incoming/" "$current/"
rm -rf -- "$incoming" "$archive"
sync
echo "publish-nfs-root: published $current"
REMOTE

echo "NFS root published successfully."
