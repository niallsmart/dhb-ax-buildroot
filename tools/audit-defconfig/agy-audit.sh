#!/bin/bash
set -euo pipefail

usage()
{
	echo "Usage: agy-audit.sh [--model MODEL] [CONFIG_FOO]"
}

selected=
agy_command=(agy)
while [ "$#" -gt 0 ]; do
	case $1 in
	-h|--help)
		usage
		exit 0
		;;
	--model)
		if [ "$#" -lt 2 ] || [ -z "$2" ]; then
			echo "agy-audit: --model requires a model name or ID" >&2
			exit 2
		fi
		agy_command+=(--model "$2")
		shift 2
		;;
	*)
		if [ -n "$selected" ]; then
			usage >&2
			exit 2
		fi
		selected=$1
		shift
		;;
	esac
done
if [ -n "$selected" ]; then
	case $selected in
	CONFIG_?*) ;;
	*) usage >&2; exit 2 ;;
	esac
	case $selected in
	*[!A-Za-z0-9_]*) usage >&2; exit 2 ;;
	esac
fi

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$directory/../.."
repo=$(pwd)
repo_replacement=$(printf '%s' "$repo" | sed 's/[\\&|]/\\&/g')
defconfig=br2-external/board/dhb-ax/linux_defconfig
if [ -n "$selected" ] && ! grep -Eq "^($selected=|# $selected is not set$)" "$defconfig"; then
	echo "agy-audit: $selected is absent from $defconfig" >&2
	exit 1
fi

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
: > "$temporary/changes"
mkdir -p "$directory/results"

show_trace()
{
	if [ -z "$selected" ]; then
		cat > /dev/null
		return
	fi
	jq --unbuffered -r '
		if .event == "init" then
			"Session: \(.conversation_id)"
		elif .event == "step_update" then
			.step_update
			| if .step_type == "tool" and .state == "ACTIVE" then
				"\n> \(.tool_name)",
				(.tool_info.parameters // {} | to_entries[] | "  \(.key): \(.value)")
			  elif .step_type == "tool" and .state == "DONE" then
				(.tool_info.output // empty)
			  else empty end
		else . end
	' >&2
}

while IFS= read -r line || [ -n "$line" ]; do
	case $line in
	CONFIG_*=*)
		config=${line%%=*}
		current=${line#*=}
		;;
	\#\ CONFIG_*\ is\ not\ set)
		config=${line#\# }
		config=${config% is not set}
		current=n
		;;
	*) continue ;;
	esac
	if [ -n "$selected" ]; then
		[ "$config" = "$selected" ] || continue
	else
		case $config in CONFIG_NET_VENDOR*) continue ;; esac
	fi

	echo "Auditing $config ($current)" >&2
	prompt=$(sed -e "s/{{CONFIG_NAME}}/$config/g" \
		-e "s|{{REPO_ROOT}}|$repo_replacement|g" "$directory/agy-audit.md")
	: > "$temporary/response.jsonl"
	"${agy_command[@]}" --project dhb-ax-defconfig-audit --add-dir "$repo" --output-format stream-json --json-schema "$directory/agy-audit.schema.json" \
		--print "$prompt" </dev/null \
		| tee -a "$directory/results/$config.jsonl" "$temporary/response.jsonl" | show_trace
	# Extract the final result from this run's stream, excluding earlier runs.
	result=$(jq -sce --arg config "$config" '
		last // error("AGY produced no output")
		| .result
		| if .status != "SUCCESS" then error("AGY audit did not succeed") else .structured_output end
		| .recommendations
		| if any(.[]; .config == $config) and
			all(.[]; [.config, .description, .recommended_setting, .rationale] | all(type == "string"))
		  then .[] | {config, description, recommended_setting, rationale}
		  else error("Invalid audit result for " + $config) end
	' "$temporary/response.jsonl")
	while IFS= read -r row; do
		symbol=$(printf '%s\n' "$row" | jq -r '.config')
		recommended=$(printf '%s\n' "$row" | jq -r '.recommended_setting')
		current=$(awk -v symbol="$symbol" '
			index($0, symbol "=") == 1 { print substr($0, length(symbol) + 2); found=1; exit }
			$0 == "# " symbol " is not set" { print "n"; found=1; exit }
			END { if (!found) print "not in defconfig" }
		' "$defconfig")
		if [ "$current" = "not in defconfig" ] && [ "$recommended" = remove ]; then
			continue
		fi
		if [ "$current" != "$recommended" ]; then
			printf '%s: %s -> %s\n' "$symbol" "$current" "$recommended" >> "$temporary/changes"
		fi
	done <<< "$result"
done < "$defconfig"

if [ -s "$temporary/changes" ]; then
	cat "$temporary/changes"
else
	echo "No recommended changes."
fi
