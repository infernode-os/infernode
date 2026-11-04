#!/bin/sh
#
# tests/host/jit_byte_test.sh
#
# Byte divide and remainder give from compiled code what the interpreter
# gives: runs tests/jit_byte_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature. The amd64 JIT's
# divb and modb were wrong (signed, the remainder from the wrong register,
# AH not cleared); found by tools/disfuzz. That the JIT compiles a module
# of fewer than 128 instructions is tests/host/jit_small_test.sh's.
#
# Skips (exit 77) when there is no emulator or the tests are not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_byte_test.dis" ] || { echo "SKIP: dis/tests/jit_byte_test.dis not built"; exit 77; }

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

exit $rc
