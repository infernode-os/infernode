#!/bin/sh
#
# tests/host/jit_big_test.sh
#
# big multiply, divide and remainder, and the head of a list of big,
# give from compiled code what they give from the interpreter.
#
# The amd64 JIT sent mull, divl, modl and headl to the interpreter;
# it compiles them now. The most negative big over -1 wraps under both.
#
# Runs tests/jit_big_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_big_test.dis" ] || { echo "SKIP: dis/tests/jit_big_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_big_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: big arithmetic as the interpreter has it under -c$c"
	else
		echo "FAIL: big arithmetic differs under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
