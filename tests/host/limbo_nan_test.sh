#!/bin/sh
#
# tests/host/limbo_nan_test.sh
#
# The compiler's comparisons of reals with a NaN (tests/limbo_nan_test.b):
# false but for !=, in a branch and as a value, and x op x not folded
# where a NaN makes the fold wrong.
#
# Runs tests/limbo_nan_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/limbo_nan_test.dis" ] || { echo "SKIP: dis/tests/limbo_nan_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/limbo_nan_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: comparisons with a NaN as IEEE has them under -c$c"
	else
		echo "FAIL: comparisons with a NaN wrong under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
