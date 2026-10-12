#!/bin/sh
#
# jsfs_test.sh — jsfs(4), JavaScript realms as files.  Runs
# tests/inferno/jsfs_test.sh in an emu.

. "$(dirname "$0")/common.sh"
cd "$ROOT"
[ -x "$EMU" ] || { echo "jsfs_test: SKIP (no emu)"; exit 77; }
mkdir -p "$ROOT/tmp"
out=$(with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "load std; sh /tests/inferno/jsfs_test.sh; echo halt > '#c/sysctl'" 2>&1)
printf '%s\n' "$out" | grep -E '^(PASS|FAIL|ALL PASS)'
printf '%s\n' "$out" | grep -q '^ALL PASS' && exit 0
echo "FAIL: jsfs_test"
printf '%s\n' "$out" | grep -vE '^(PASS|FAIL)' | sed 's/^/    /'
exit 1
