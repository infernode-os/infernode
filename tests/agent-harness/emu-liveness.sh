#!/bin/sh
# Report emulator liveness without mistaking a zombie leader for a dead process.

set -eu

usage()
{
	echo "usage: emu-liveness.sh pid [quota-pause-marker]" >&2
	exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
pid=$1
case "$pid" in
	*[!0-9]*|'') usage ;;
esac
[ "$pid" -gt 0 ] || usage

proc=${PROC_ROOT:-/proc}
pause=${2:-}
quota=running
[ -n "$pause" ] && [ -e "$pause" ] && quota=quota-paused

taskdir=$proc/$pid/task
if [ -d "$taskdir" ]; then
	total=0
	live=0
	leader=unknown
	for status in "$taskdir"/*/status; do
		[ -r "$status" ] || continue
		state=$(awk '/^State:/{print $2; exit}' "$status")
		[ -n "$state" ] || continue
		total=$((total + 1))
		case "$status" in
			"$taskdir/$pid/status") leader=$state ;;
		esac
		case "$state" in
			Z|X|x) ;;
			*) live=$((live + 1)) ;;
		esac
	done
	if [ "$live" -gt 0 ]; then
		echo "LIVE pid=$pid leader_state=$leader live_threads=$live total_threads=$total state=$quota"
		exit 0
	fi
	if [ "$total" -gt 0 ]; then
		echo "EXITED pid=$pid leader_state=$leader live_threads=0 total_threads=$total state=$quota"
		exit 1
	fi
fi

if kill -0 "$pid" 2>/dev/null; then
	echo "LIVE_UNVERIFIED pid=$pid state=$quota"
	exit 0
fi

echo "EXITED pid=$pid state=$quota"
exit 1
