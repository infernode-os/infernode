#!/bin/sh
# Regression checks for emulator thread-group liveness diagnosis.

set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CHECK="$ROOT/tests/agent-harness/emu-liveness.sh"
[ -x "$CHECK" ] || { echo "FAIL: $CHECK missing or not executable" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/emu-liveness-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
proc=$work/proc

mkdir -p "$proc/42/task/42" "$proc/42/task/43"
printf 'State:\tZ (zombie)\n' > "$proc/42/task/42/status"
printf 'State:\tS (sleeping)\n' > "$proc/42/task/43/status"

out=$(PROC_ROOT="$proc" "$CHECK" 42)
echo "$out" | grep -q '^LIVE .*leader_state=Z .*live_threads=1' || {
	echo "FAIL: zombie leader with live worker was not reported live: $out" >&2
	exit 1
}

: > "$work/quota-paused"
out=$(PROC_ROOT="$proc" "$CHECK" 42 "$work/quota-paused")
echo "$out" | grep -q 'state=quota-paused$' || {
	echo "FAIL: quota pause was not reported as live state: $out" >&2
	exit 1
}

printf 'State:\tZ (zombie)\n' > "$proc/42/task/43/status"
if out=$(PROC_ROOT="$proc" "$CHECK" 42); then
	echo "FAIL: all-zombie thread group was reported live: $out" >&2
	exit 1
fi
echo "$out" | grep -q '^EXITED .*live_threads=0' || {
	echo "FAIL: all-zombie result is malformed: $out" >&2
	exit 1
}

if "$CHECK" invalid >/dev/null 2>&1; then
	echo "FAIL: invalid pid was accepted" >&2
	exit 1
fi

echo "emu_liveness_test: PASS"
