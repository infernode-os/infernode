#!/bin/sh
#
# tests/host/jit_builtinexc_test.sh
#
# An exception a builtin raises inside a handler block is caught by that block,
# in the calling function's frame, from compiled code as from the
# interpreter: runs tests/jit_builtinexc_test.b under -c0 and -c1, each of
# which must print the framework's PASS line and no crash signature. The
# JITs called the builtin with R.PC stale, and the handler search took the
# builtin's frame for the caller's (destroy of nil, a nil frame pointer); found by
# tools/sysfuzz with a main pool too small.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_builtinexc_test.dis" ] || { echo "SKIP: dis/tests/jit_builtinexc_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_builtinexc_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: a builtin's exception caught in its caller under -c$c"
	else
		echo "FAIL: a builtin's exception under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
