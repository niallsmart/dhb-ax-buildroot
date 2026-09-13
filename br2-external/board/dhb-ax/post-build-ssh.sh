#!/bin/sh
# Install the machine-local SSH identity for the Buildroot image.
set -eu

target=${1:-$TARGET_DIR}
local_ssh=${2:-}

# The local key directory holds OpenSSH host keys.  Copying them into
# the image preserves the host identity across upgrades and initramfs boots.
if [ -z "$local_ssh" ]; then
	echo "post-build-ssh: local SSH input directory argument is missing" >&2
	exit 1
fi

host_keys="
ssh_host_rsa_key
ssh_host_ecdsa_key
ssh_host_ed25519_key
"
for file in $host_keys authorized_keys; do
	if [ ! -f "$local_ssh/$file" ]; then
		echo "post-build-ssh: missing local SSH input: $local_ssh/$file" >&2
		exit 1
	fi
done

install -d -m 0700 "$target/root/.ssh"
install -m 0600 "$local_ssh/authorized_keys" \
	"$target/root/.ssh/authorized_keys"

install -d -m 0755 "$target/etc/ssh"
for file in $host_keys; do
	install -m 0600 "$local_ssh/$file" "$target/etc/ssh/$file"
done

echo "post-build-ssh: installed OpenSSH host and root authorized keys"
