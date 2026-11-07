#!/bin/sh
#
# tests/host/strcat_test.sh
#
# s += s and s = s + s leave the heap whole, under the interpreter and
# the JIT alike.  addstring (libinterp/string.c) appended in place,
# setting the new length before copying the right operand; when the
# right was the left, it copied twice what it should, past the end of
# the block, and the emulator died later, elsewhere.
#
# Runs tests/strcat_test.b under -c0 and -c1, each of which must print
# the framework's PASS line (a corrupt heap panics at its pool audit).
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/strcat_test.dis" ] || { echo "SKIP: dis/tests/strcat_test.dis not built"; exit 77; }

rc=0
for c in 0 1; do
	out=$(timeout 60 "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/strcat_test.dis; echo halt > /dev/sysctl" 2>&1)
	if echo "$out" | grep -q "^PASS$"; then
		echo "PASS: a string appended to itself leaves the heap whole under -c$c"
	else
		echo "FAIL: a string appended to itself under -c$c:"
		echo "$out" | grep -v sdl3 | head -12
		rc=1
	fi
done
exit $rc
