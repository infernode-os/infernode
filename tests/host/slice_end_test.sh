#!/bin/sh
#
# tests/host/slice_end_test.sh
#
# The interpreter ends a Prog's time slice only where compiled code's
# would end: after a backward branch, a call or a return. Runs
# tests/slice_end_test.b under -c0 and -c1, each of which must print
# the framework's PASS line.
#
# `a[i] = v` is two instructions (the element's address, then the store
# through it) with nothing holding the array between them, which is
# sound only if no other Prog can run between the two. The interpreter
# ended a slice wherever its count of instructions ran out: a Prog that
# replaced the array at that moment had the other's store land in
# whatever was allocated in the array's place, within a few rounds.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/slice_end_test.dis" ] || { echo "SKIP: dis/tests/slice_end_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-180}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/slice_end_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: a store through an element's address is not parted from it by another Prog, under -c$c"
	else
		echo "FAIL: slice_end_test under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
