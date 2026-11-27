#!/bin/sh
#
# tests/host/jit_callresched_test.sh
#
# A recursion with no loop in it gives up the VM while it runs.
#
# The arm64 and riscv64 JITs checked the time slice only at backward
# jumps, never at a call, so a compiled recursion kept the VM until it
# returned: jitbench's fib(30) held a Pi Zero 2 W's for 4.7 s, and every
# other Prog in it waited.  Runs tests/jit_callresched_test.b under -c0
# and -c1; each must print the framework's PASS line and no crash
# signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_callresched_test.dis" ] || { echo "SKIP: dis/tests/jit_callresched_test.dis not built"; exit 77; }
mkdir -p "$ROOT/tmp"

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_callresched_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|--- SKIP\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: a recursion gives up the VM under -c$c"
		echo "$out" | grep 'worst ticker lateness' | sed 's/^/    /'
	else
		echo "FAIL: a recursion kept the VM under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
