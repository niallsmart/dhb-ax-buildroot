#!/bin/sh
# Run a command on the DVR's serial console and print only that command's output.
#
#   tools/dvr-console-exec.sh 'uname -a'
#   tools/dvr-console-exec.sh 'cat /proc/mtd'
#   SESSION=dvr2 TIMEOUT=30 tools/dvr-console-exec.sh 'dmesg | tail -40'
#
# The console is a durable picocom session running under tmux (see `just dvr`).
# Full scrollback is useful for forensics; this helper instead wraps one command
# in unique markers and returns only that command's output.
#
# This sends whatever you give it. The project's rule that nothing writes to
# the DVR's flash or disk is not enforced here — it is on the caller.
set -eu

SESSION=${SESSION:-dvr}     # tmux session holding the picocom console
TIMEOUT=${TIMEOUT:-20}      # seconds to wait for the command to finish

if [ $# -eq 0 ]; then
	echo "usage: ${0##*/} 'command to run on the DVR'" >&2
	exit 1
fi
cmd=$*

case $SESSION in
	*[!A-Za-z0-9_.-]*)
		echo "error: unsafe tmux session name: $SESSION" >&2
		exit 1
		;;
esac

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
	echo "error: no tmux session '$SESSION'; start it with: just dvr" >&2
	exit 1
fi

lock=/tmp/dvr-tmux-$SESSION.lock
if ! mkdir "$lock" 2>/dev/null; then
	echo "error: another DVR console tool holds $lock" >&2
	exit 1
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

# Markers carry a per-run nonce, which is what makes reading the pane safe:
# every previous run's markers are still sitting in the scrollback, so fixed
# markers would let the wait below match a stale end marker immediately and
# return the wrong command's output.
#
# They are also split by an empty string so they survive one round of shell
# echo. The console echoes the command line back before running it, and the
# remote shell concatenates ==ST""ART-n== into ==START-n==, so only the real
# output matches. Both tricks are needed; either alone still misreads.
#
# Nothing is cleared, on the pane or in the scrollback. The nonce makes it
# unnecessary, and this session is usually one a human is watching — wiping
# their history out from under them to save an awk filter is a bad trade.
nonce="$$-$(date +%s)"
start="==ST\"\"ART-$nonce=="
end="==E\"\"ND-$nonce=="

tmux send-keys -t "$SESSION" "echo $start; $cmd; echo $end" Enter

# Poll for the closing marker rather than sleeping a fixed amount: a slow
# command should not be truncated, and a fast one should not cost 20 seconds.
waited=0
limit=$((TIMEOUT * 10))
while [ "$waited" -lt "$limit" ]; do
	if tmux capture-pane -p -S - -t "$SESSION" | tr -d '\r' |
		grep -qx "==END-$nonce=="; then
		break
	fi
	sleep 0.1
	waited=$((waited + 1))
done

tmux capture-pane -p -S - -t "$SESSION" | tr -d '\r' |
	awk -v s="==START-$nonce==" -v e="==END-$nonce==" '
		$0 == s  {buf = ""; inside = 1; next}
		$0 == e  {if (inside) {out = buf; inside = 0}; next}
		inside   {buf = buf $0 "\n"}
		# If the end marker never arrived (a timeout, or a command that is
		# still running), emit what did arrive rather than nothing.
		END      {if (inside) out = buf; printf "%s", out}
	'

if [ "$waited" -ge "$limit" ]; then
	echo "${0##*/}: timed out after ${TIMEOUT}s; output above may be partial" >&2
	exit 1
fi
