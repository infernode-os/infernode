#!/bin/sh
# Deterministic host helper used only by speech_e2e_test.sh.

set -eu

mode=${1:?mode required}
state=${2:?state directory required}
shift 2

wait_for_input()
{
	path=$1
	i=0
	while [ ! -s "$path" ]; do
		i=$((i + 1))
		if [ "$i" -ge 1600 ]; then
			echo "error: timed out waiting for $(basename "$path")"
			exit 1
		fi
		sleep 0.05
	done
}

case "$mode" in
wake|listen)
	input=$state/$mode.next
	wait_for_input "$input"
	cat "$input"
	: > "$input"
	;;
say)
	cat > "$state/say.last"
	{
		echo "--- say ---"
		cat "$state/say.last"
	} >> "$state/say.log"
	: > "$state/say.started"
	rm -f "$state/say.done"
	i=0
	while [ "$i" -lt 12 ]; do
		dd if=/dev/zero bs=2048 count=1 2>/dev/null
		i=$((i + 1))
		sleep 0.02
	done
	: > "$state/say.done"
	;;
*)
	echo "speech_e2e_helper: unknown mode: $mode" >&2
	exit 2
	;;
esac
