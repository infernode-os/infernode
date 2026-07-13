#!/bin/bash

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
CANARY="$ROOT/lib/veltro/write-capability-canary"
PROBE="$ROOT/dis/veltro/exec_ro_write_probe.dis"
SUPPORT_CANARIES=(
	"$ROOT/lib/veltro/exec-support-canary"
	"$ROOT/lib/certs/exec-support-canary"
	"$ROOT/dis/veltro/exec-support-canary"
)
trap 'rm -f "$CANARY" "$PROBE" "$ROOT/tmp/veltro/scratch/77/private" "${SUPPORT_CANARIES[@]}"' EXIT

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }

timeout 30 "$EMU" -r"$ROOT" /dis/sh.dis -c \
	'limbo -I module -o dis/veltro/exec_ro_write_probe.dis tests/exec_ro_write_probe.b' \
	</dev/null >/tmp/exec-ro-write-probe-build.log 2>&1
rc=$?
emu_timeout_ok "$rc" || { cat /tmp/exec-ro-write-probe-build.log; exit 1; }
[[ -s "$PROBE" ]] || { cat /tmp/exec-ro-write-probe-build.log; echo "ERROR: failed to build $PROBE"; exit 1; }

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
	emu_timeout_ok "$rc"
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

echo original >"$CANARY"
runemu "tools9p -p /lib/veltro:ro exec & sleep 2; echo '/dis/veltro/exec_ro_write_probe.dis /lib/veltro/write-capability-canary' > /tool/exec/run; sleep 3; cat /tool/exec/run; echo HOST; cat /lib/veltro/write-capability-canary"
grep -q '^original$' <<<"$OUTPUT" || { echo "FAIL: exec mutated an ro path grant"; echo "$OUTPUT"; exit 1; }
echo "PASS: exec cannot write through an ro path grant"

for target in /lib/veltro/exec-support-canary /lib/certs/exec-support-canary /dis/veltro/exec-support-canary; do
	host="$ROOT${target}"
	rm -f "$host"
	runemu "tools9p exec & sleep 2; echo '/dis/veltro/exec_ro_write_probe.dis $target' > /tool/exec/run; sleep 3; cat /tool/exec/run; echo DONE"
	grep -q '^DONE$' <<<"$OUTPUT" || { echo "FAIL: exec support-tree probe did not complete for $target"; echo "$OUTPUT"; exit 1; }
	[[ ! -e "$host" ]] || { echo "FAIL: exec persisted write to support tree $target"; echo "$OUTPUT"; exit 1; }
done
echo "PASS: exec support-tree writes are ephemeral or denied"

runemu "tools9p -a 77 write & sleep 2; echo /tmp/veltro/shared-root denied > /tool/write/run; sleep 2; cat /tool/write/run; echo /tmp/veltro/scratch/private allowed > /tool/write/run; sleep 2; cat /tool/write/run; echo SCRATCH; cat /tmp/veltro/scratch/77/private"
grep -q "not covered by an rw path grant" <<<"$OUTPUT" || { echo "FAIL: shared workspace root write was not denied"; exit 1; }
grep -q '^allowed$' <<<"$OUTPUT" || { echo "FAIL: activity scratch write did not succeed"; exit 1; }
echo "PASS: generic writes are confined to activity scratch"
