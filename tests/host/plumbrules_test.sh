#!/bin/sh
#
# plumbrules_test.sh — lib/sh/plumbrules: the user's plumbing rules
# first, then the defaults; a broken user file never leaves the system
# without plumbing.  Runs tests/inferno/plumbrules_test.sh in an emu.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "plumbrules_test: SKIP (no emu)"; exit 77; }
mkdir -p "$ROOT/tmp"
out=$(with_timeout 60 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "load std; sh /tests/inferno/plumbrules_test.sh; echo halt > '#c/sysctl'" 2>&1)
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|ALL PASS)'
printf '%s\n' "$out" | grep -q '^ALL PASS' && exit 0
echo "FAIL: plumbrules_test"
printf '%s\n' "$out" | grep -vE '^(PASS|FAIL)' | sed 's/^/    /'
exit 1
