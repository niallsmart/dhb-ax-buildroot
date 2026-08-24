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
#                           by it and export it. Leaves $env_file set to PATH
#                           for callers that report further problems against
#                           it.
#   require_ipaddr VAR [VAR ...]
#                           Validate that each named VAR holds only digits
#                           and dots. Meant for values already confirmed
#                           non-empty by require_env_file; guards against a
#                           malformed local.env value breaking -- rather than
#                           just mismatching -- something built from it, such
#                           as a remote process-match pattern.

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
		export "$var"
	done
}

require_ipaddr() {
	for var in "$@"; do
		eval "value=\${$var:-}"
		case $value in
		'' | *[!0-9.]*)
			echo "$var does not look like an IPv4 address: $value" >&2
			exit 1
			;;
		esac
	done
}
