#!/bin/sh
#
# tests/host/refadt_zero_test.sh
#
# `t := ref T;` -- an adt allocated with no initializer -- zero-fills its
# scalar members, and does so under the interpreter and the JIT alike.
#
# The compiler used to emit the Dis `new` instruction for this form, and
# `new` left the non-pointer slots holding whatever the recycled pool
# block last contained.  Every JIT punts `new` to the same interpreter
# op, so the two modes disagreed only because their allocation histories
# differ; that is what made it look like a JIT bug when Charon's layout
# engine lost a grid column.  The compiler now emits `newz` for this
# form and heap() zero-fills either way.
#
# Runs the Limbo unit test under -c0 and -c1 (tests/refadt_zero_test.b
# poisons the heap first so recycled memory is non-zero), each of which
# must print the framework's PASS line.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/refadt_zero_test.dis" ] || { echo "SKIP: dis/tests/refadt_zero_test.dis not built"; exit 77; }

rc=0
for c in 0 1; do
	out=$(timeout 60 "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/refadt_zero_test.dis; echo halt > /dev/sysctl" 2>&1)
	if echo "$out" | grep -q "^PASS$"; then
		echo "PASS: ref T zero-fills its scalar members under -c$c"
	else
		echo "FAIL: ref T is not zero-filled under -c$c:"
		echo "$out" | grep -v sdl3 | head -12
		rc=1
	fi
done
exit $rc
