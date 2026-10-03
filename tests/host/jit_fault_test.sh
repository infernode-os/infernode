#!/bin/sh
#
# tests/host/jit_fault_test.sh
#
# A zero divide, a nil list or ref dereference and an out-of-range
# index raise the interpreter's exception from compiled code, and the
# handler around the faulting instruction catches it.
#
# The arm64 JIT gave 0 for a zero divide, raised "array bounds error"
# for hd nil, and raised its bounds and nil faults, and every punted
# op's errors, with R.PC still naming the last call, so no handler
# around the fault matched; the hosted emulators raised a nil ref
# load's hardware fault, and x86's divide trap, with R.PC just as stale,
# the divide as "sys: fp: ...".
#
# Runs tests/jit_fault_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_fault_test.dis" ] || { echo "SKIP: dis/tests/jit_fault_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_fault_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: faults in compiled code raise the interpreter's exceptions under -c$c"
	else
		echo "FAIL: faults are not raised or not caught under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
