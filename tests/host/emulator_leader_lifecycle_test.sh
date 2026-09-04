#!/bin/sh
# A long-lived pthread emulator must keep its advertised process leader alive.

set -eu

ROOT=${ROOT:-}
. "$(dirname "$0")/common.sh"

[ "$EMUHOST" = Linux ] || { echo "SKIP: Linux /proc test"; exit 77; }
[ -r /proc/self/status ] || { echo "SKIP: /proc unavailable"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: sh.dis not built"; exit 77; }
command -v setsid >/dev/null 2>&1 || { echo "SKIP: setsid unavailable"; exit 77; }

work=${TMPDIR:-/tmp}/infernode-leader-$$
mkdir -p "$work"
pid=
watchdog=
cleanup()
{
	if [ -n "$watchdog" ]; then
		kill "$watchdog" 2>/dev/null || true
		wait "$watchdog" 2>/dev/null || true
	fi
	if [ -n "$pid" ]; then
		kill -KILL -"$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

setsid "$EMU" -r"$ROOT" /dis/sh.dis -c 'sleep 30' >"$work/emu.log" 2>&1 &
pid=$!

n=0
while [ "$n" -lt 50 ]; do
	state=$(awk '/^State:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
	threads=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
	[ -n "$state" ] && [ "${threads:-0}" -gt 1 ] && break
	sleep 0.1
	n=$((n + 1))
done

if [ -z "${state:-}" ] || [ "${threads:-0}" -le 1 ]; then
	echo "FAIL: emulator did not reach its worker-thread run state"
	cat "$work/emu.log"
	exit 1
fi

if [ "$state" = Z ]; then
	echo "FAIL: emulator process leader is a zombie while $threads threads run"
	exit 1
fi

timeout_marker=$work/shutdown-timeout
(
	sleep 5
	: >"$timeout_marker"
	kill -KILL -"$pid" 2>/dev/null || true
) &
watchdog=$!

kill -TERM "$pid"
set +e
wait "$pid" 2>/dev/null
set -e
pid=
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
watchdog=

[ ! -e "$timeout_marker" ] || {
	echo "FAIL: emulator did not terminate after SIGTERM"
	exit 1
}

echo "PASS: emulator leader state=$state with $threads threads; SIGTERM stopped it"
