#!/bin/sh
#
# tests/host/shift_count_test.sh
#
# A shift by its operand's width or more gives the same answer from the
# interpreter and the JIT: the count mod 64, the value as 64 bits, the
# result cut to size.  Byte and big shifts were undefined in the
# interpreter's C: 200 << 33 was 144 there and from amd64's JIT, 0 from
# arm64's and riscv64's (disfuzz).  Runs tests/shift_count_test.b under
# -c0 and -c1; each must print the framework's PASS line and no crash
# signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/shift_count_test.dis" ] || { echo "SKIP: dis/tests/shift_count_test.dis not built"; exit 77; }
mkdir -p "$ROOT/tmp"

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/shift_count_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|--- SKIP\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: shifts agree with the interpreter under -c$c"
	else
		echo "FAIL: a shift gave the wrong answer under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
