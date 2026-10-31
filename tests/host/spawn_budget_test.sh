#!/bin/sh
#
# spawn_budget_test.sh — a subagent spawned through tools9p loads the
# tools in the delegation budget, and only those (INFR-486).
#
# Runs tests/spawn_budget_test.dis against a tools9p serving spawn with
# a budget of plan and read. Before the fix every child failed with
# "cannot load tool plan": tools9p narrowed the spawn call's namespace
# to spawn.dis alone. No model is needed.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/spawn.dis dis/veltro/tools/plan.dis dis/tests/spawn_budget_test.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

OUT=$(mktemp)
EMUPID=
trap 'rm -f "$OUT"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM
# emu does not exit while tools9p serves: wait for the marker, then stop it.
"$EMU" -r"$ROOT" /dis/sh.dis -c \
	"path=(/dis/veltro /dis/cmd /dis .); tools9p -b plan,read spawn read & sleep 3; /dis/tests/spawn_budget_test.dis -v; echo '=== SPAWN BUDGET DONE'" \
	</dev/null >"$OUT" 2>&1 &
EMUPID=$!
i=0
while [ $i -lt 90 ] && ! grep -q '=== SPAWN BUDGET DONE' "$OUT"; do
	sleep 1
	i=$((i + 1))
done

if ! grep -q '=== SPAWN BUDGET DONE' "$OUT"; then
	tail -20 "$OUT"
	echo "FAIL: spawn_budget_test did not finish"
	exit 1
fi
if grep -q '^--- FAIL' "$OUT" || ! grep -q '^3 passed' "$OUT"; then
	grep -E -A6 -- '^--- (FAIL|SKIP)|^=== RUN' "$OUT" || tail -20 "$OUT"
	echo "FAIL: spawn through tools9p did not load exactly the budget's tools"
	exit 1
fi
echo "PASS: a spawned child loads budget tools and cannot load others"
echo "spawn_budget_test: PASS"
