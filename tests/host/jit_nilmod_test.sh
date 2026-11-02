#!/bin/sh
#
# tests/host/jit_nilmod_test.sh
#
# A call through a nil module reference raises "module not loaded" where
# the handler around it catches it, from compiled code as from the
# interpreter: runs tests/jit_nilmod_test.b under -c0 and -c1, each of
# which must print the framework's PASS line and no crash signature. The
# amd64 JIT's mframe and mcall raised it (or "dereference of nil") where
# no handler in the caller saw it; found by tools/disfuzz.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_nilmod_test.dis" ] || { echo "SKIP: dis/tests/jit_nilmod_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_nilmod_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: a nil module's call is caught where it is made under -c$c"
	else
		echo "FAIL: a nil module's call under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
