#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
PROBE="$ROOT/dis/veltro/exec_confinement_probe.dis"
log=$(mktemp)
trap 'rm -f "$log" "$PROBE"' EXIT

"$EMU" -r"$ROOT" /dis/sh.dis -c \
	'limbo -I module -o dis/veltro/exec_confinement_probe.dis tests/exec_confinement_probe.b' \
	</dev/null >"$log" 2>&1 || { cat "$log"; exit 1; }

timeout 15 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'path=(/dis/veltro /dis/cmd /dis .); tools9p exec & sleep 2; echo /dis/veltro/exec_confinement_probe.dis > /tool/exec/run; sleep 3; cat /tool/exec/run; echo DONE' \
	</dev/null >"$log" 2>&1
rc=$?
output=$(cat "$log")

[[ $rc -eq 0 || $rc -eq 124 ]] || { echo "$output"; exit 1; }
grep -q DONE <<<"$output" || { echo "FAIL: exec probe did not complete"; echo "$output"; exit 1; }
if grep -q 'PASS: exec process and device capabilities are confined' <<<"$output"; then
	echo "PASS: exec uses only its private wait FD and process namespace"
else
	echo "FAIL: exec confinement probe failed"; echo "$output"; exit 1
fi
