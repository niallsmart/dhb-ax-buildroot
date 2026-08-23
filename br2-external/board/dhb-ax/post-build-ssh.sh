#!/bin/sh
# Install the machine-local SSH identity shared by the production and
# diagnostic images.
set -eu

target=${1:-$TARGET_DIR}
local_ssh=${2:-}

# The local key directory holds Dropbear-native host keys.  Copying them into
# each image preserves the host identity across main-image upgrades and
# diagnostic-image boots.
if [ -z "$local_ssh" ]; then
	echo "post-build-ssh: local SSH input directory argument is missing" >&2
	exit 1
fi

host_keys="
dropbear_rsa_host_key
dropbear_ecdsa_host_key
dropbear_ed25519_host_key
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

# Buildroot installs /etc/dropbear as a symlink to a runtime directory. Use a
# real directory so the machine-local host keys are part of the image.
if [ -L "$target/etc/dropbear" ]; then
	rm "$target/etc/dropbear"
fi
install -d -m 0700 "$target/etc/dropbear"
for file in $host_keys; do
	install -m 0600 "$local_ssh/$file" "$target/etc/dropbear/$file"
done

echo "post-build-ssh: installed Dropbear host and root authorized keys"
