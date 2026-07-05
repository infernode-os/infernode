#!/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
CANARY="$ROOT/lib/veltro/write-capability-canary"
trap 'rm -f "$CANARY" "$ROOT/tmp/veltro/scratch/77/private"' EXIT

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

runemu() {
	local command="$1"
	local log
	log=$(mktemp)
	timeout 12 "$EMU" -r"$ROOT" /dis/sh.dis -c \
		"path=(/dis/veltro /dis/cmd /dis .); $command" \
		</dev/null >"$log" 2>&1
	local rc=$?
	OUTPUT=$(cat "$log")
	rm -f "$log"
	[[ $rc -eq 0 || $rc -eq 124 ]]
}

echo original >"$CANARY"
runemu "tools9p write edit & sleep 2; echo /lib/veltro/write-capability-canary changed > /tool/write/run; sleep 2; cat /tool/write/run; echo /lib/veltro/write-capability-canary original changed-edit > /tool/edit/run; sleep 2; cat /tool/edit/run; echo HOST; cat /lib/veltro/write-capability-canary"
denials=$(grep -o "not covered by an rw path grant" <<<"$OUTPUT" | wc -l | tr -d ' ')
[[ $denials -ge 2 ]] || { echo "FAIL: ungranted write/edit were not both denied"; exit 1; }
grep -q '^original$' <<<"$OUTPUT" || { echo "FAIL: ungranted write/edit changed parent file"; exit 1; }
echo "PASS: ungranted write and edit are read-only"

echo original >"$CANARY"
runemu "tools9p -p /lib/veltro:ro write & sleep 2; echo /lib/veltro/write-capability-canary changed > /tool/write/run; sleep 2; cat /tool/write/run; echo HOST; cat /lib/veltro/write-capability-canary"
grep -q "is read-only" <<<"$OUTPUT" || { echo "FAIL: ro write was not denied"; exit 1; }
grep -q '^original$' <<<"$OUTPUT" || { echo "FAIL: ro write changed parent file"; exit 1; }
echo "PASS: explicit ro grant is enforced"

runemu "tools9p -a 77 write & sleep 2; echo /tmp/veltro/shared-root denied > /tool/write/run; sleep 2; cat /tool/write/run; echo /tmp/veltro/scratch/private allowed > /tool/write/run; sleep 2; cat /tool/write/run; echo SCRATCH; cat /tmp/veltro/scratch/77/private"
grep -q "not covered by an rw path grant" <<<"$OUTPUT" || { echo "FAIL: shared workspace root write was not denied"; exit 1; }
grep -q '^allowed$' <<<"$OUTPUT" || { echo "FAIL: activity scratch write did not succeed"; exit 1; }
echo "PASS: generic writes are confined to activity scratch"
