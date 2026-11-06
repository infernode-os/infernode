#!/bin/bash
#
# tests/host/exec_reap_test.sh
#
# INFR-421 regression: nothing started through the exec tool may outlive the
# call. restrictns empties /prog for the exec worker, so the tool must kill the
# worker's process group through a ctl it opened before dropping device access,
# and must do so on every return — a command that overruns the deadline, and a
# command backgrounded with a non-trailing '&', alike.
#
# Run from project root: ./tests/host/exec_reap_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
SH="/dis/sh.dis"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED+1)); }
total() { echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"; }

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -x "$LIMBO" && -f "$ROOT/dis/veltro/tools/exec.dis" ]] || {
	skip "limbo or exec.dis not built"; total; exit 0; }

name="exec-reap-$$"
script="$ROOT/tmp/$name.sh"
log="$ROOT/tmp/$name.log"
sdk="$ROOT/tmp/veltro/probe-sdk"
mkdir -p "$sdk"
trap 'rm -f "$script" "$log" "$sdk/exec-reap-sleeper.dis"' EXIT HUP INT TERM

"$LIMBO" -I"$ROOT/module" -gw -o "$sdk/exec-reap-sleeper.dis" "$ROOT/tests/exec_reap_sleeper.b" || {
	fail "cannot compile exec_reap_sleeper.b"; total; exit 1; }

cat > "$script" <<'EOF'
load std
path=(/dis/veltro /dis/cmd /dis .)
tools9p -N -m /tool -b exec -p /tmp/veltro/probe-sdk:rw exec >[2] /dev/null &
for (i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20) {
	if {! ftest -d /tool/exec} { sleep 1 }
}
# -t 3: the sleeper overruns a short deadline, so both arms finish well inside
# the emulator's timeout (the default deadline is 30 seconds).
for (arm in deadline ampersand) {
	if {~ $arm deadline} { echo '-t 3 /tmp/veltro/probe-sdk/exec-reap-sleeper.dis' > /tool/exec/run }
	if {~ $arm ampersand} { {echo '-t 3 /tmp/veltro/probe-sdk/exec-reap-sleeper.dis &'; echo 'whatis x'} > /tool/exec/run }
	cat /tool/exec/run > /dev/null
	sleep 2
	echo SURVIVORS $arm `{ps | grep ExecReapSleeper | wc -l}
	for (p in `{ps | grep ExecReapSleeper | awk '{print $1}'}) { echo kill > /prog/$p/ctl }
}
echo REAP_DONE
EOF

timeout 60 "$EMU" -r"$ROOT" "$SH" "/tmp/$name.sh" </dev/null >"$log" 2>&1
OUTPUT=$(cat "$log")
[[ "$VERBOSE" -eq 1 ]] && echo "$OUTPUT"

if ! grep -q '^REAP_DONE$' <<<"$OUTPUT"; then
	fail "exec reap probe did not complete (output: $OUTPUT)"
	total; exit 1
fi
for arm in deadline ampersand; do
	n=$(sed -n "s/^SURVIVORS $arm \([0-9][0-9]*\)$/\1/p" <<<"$OUTPUT")
	if [[ "$n" == "0" ]]; then
		pass "exec $arm command does not outlive the tool call"
	else
		fail "exec $arm command left ${n:-?} process(es) alive after the tool returned"
	fi
done
total
[[ "$FAILED" -eq 0 ]]
