#!/bin/sh
#
# tests/host/nil_far_test.sh
#
# A field far into a nil ref adt is "dereference of nil", caught by the
# handler round it, from compiled code as from the interpreter: runs
# tests/nil_far_test.b under -c0 and -c1, each of which must print the
# framework's PASS line and leave no Prog broken. The fault was taken
# for a nil dereference only below address 512; a field at offset 560,
# 4800 or 65520 gave "sys: segmentation violation" under -c0, and under
# -c1 was not caught at all (the Prog died, Broken).
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/nil_far_test.dis" ] || { echo "SKIP: dis/tests/nil_far_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/nil_far_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: a nil ref's far field is a nil dereference, caught where it is made, under -c$c"
	else
		echo "FAIL: a nil ref's far field under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
