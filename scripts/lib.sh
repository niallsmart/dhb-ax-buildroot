# Shared setup for the DHB_AX host-side tooling: tools/dvr-*.sh,
# scripts/buildroot-in-container.sh and the Justfile's dvr recipe. Not
# itself executable; source it after `set -eu`.
#
#   . "$repo/scripts/lib.sh"
#
# Defines:
#   require_env_file PATH [VAR ...]
#                           Validate that PATH exists and source it, with the
#                           standard message when it does not, then check
#                           that each named VAR was set to something non-empty
#                           by it. Leaves $env_file set to PATH for callers
#                           that report further problems against it.

require_env_file() {
	env_file=$1
	shift
	[ -f "$env_file" ] || {
		echo "no machine-local configuration at $env_file" >&2
		echo "create it with: install -m 600 local.env.example local.env" >&2
		exit 1
	}
	# shellcheck source=/dev/null
	. "$env_file"
	for var in "$@"; do
		eval "value=\${$var:-}"
		[ -n "$value" ] || {
			echo "$var must be set in $env_file" >&2
			exit 1
		}
	done
}
