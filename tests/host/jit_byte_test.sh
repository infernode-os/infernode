#!/bin/sh
#
# tests/host/jit_byte_test.sh
#
# Byte divide and remainder give from compiled code what the interpreter
# gives, and the JIT compiles a module of fewer than 128 instructions.
#
# Runs tests/jit_byte_test.b under -c0 and -c1, each of which must print
# the framework's PASS line and no crash signature. Then runs
# tests/jit_small_helper.b under -c4, where a JIT that says what it
# compiles (amd64, riscv64: "dis= ...: Module") must name it, and it must
# print 7 % 5. The amd64 JIT's divb and modb were wrong (signed, the
# remainder from the wrong register, AH not cleared), and its compile()
# refused every module under 128 instructions, so they ran interpreted
# under -c1 saying nothing; both found by tools/disfuzz.
#
# Skips (exit 77) when there is no emulator or the tests are not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_byte_test.dis" ] || { echo "SKIP: dis/tests/jit_byte_test.dis not built"; exit 77; }
[ -f "$ROOT/dis/tests/jit_small_helper.dis" ] || { echo "SKIP: dis/tests/jit_small_helper.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_byte_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: byte / and % as the interpreter has them under -c$c"
	else
		echo "FAIL: byte / and % differ under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done

out=$(with_timeout "$TIMEOUT" "$EMU" -c4 -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_small_helper.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
if ! echo "$out" | grep -q "^small 2$"; then
	echo "FAIL: the small module under -c4 did not print 7 % 5:"
	echo "$out" | grep -v '^macro\|^comvec\|^typ=\|^mcall\|^\[' | head -10
	rc=1
elif ! echo "$out" | grep -q '^dis='; then
	echo "PASS: the small module runs under -c4 (this JIT does not say what it compiles)"
elif echo "$out" | grep -q '^dis=.*: JitSmall$'; then
	echo "PASS: the JIT compiles a module of fewer than 128 instructions"
else
	echo "FAIL: the JIT did not compile the small module (it ran interpreted):"
	echo "$out" | grep '^dis=' | head -5
	rc=1
fi
exit $rc
