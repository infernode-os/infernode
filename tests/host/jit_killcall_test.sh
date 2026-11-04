#!/bin/sh
#
# tests/host/jit_killcall_test.sh
#
# An exception that arrives during a call to a builtin is raised at the call, where
# the handler around the call catches it, from compiled code as from the
# interpreter: runs tests/jit_killcall_test.b under -c0 and -c1, each of
# which must print the framework's PASS line and no crash signature. The
# JITs' rmcall raised it with R.PC stale, and another block's handler took
# it (or another function's, freeing what were not its locals); found by
# tools/sysfuzz.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_killcall_test.dis" ] || { echo "SKIP: dis/tests/jit_killcall_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_killcall_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: an exception during a builtin call caught at the call under -c$c"
	else
		echo "FAIL: an exception during a builtin call under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
