#!/bin/sh
#
# tests/host/jit_bounds_test.sh
#
# An out-of-range array, string or slice index raises "array bounds
# error" from compiled code as it does from the interpreter, and the
# handler around the index catches it.
#
# bflag, which gates the bounds check in the amd64 and arm64 JITs, was
# declared zero and nothing set it (emu -b was documented as on by
# default), so those JITs compiled every index with no check at all: a
# negative index read or wrote outside the array, and emu died in a
# segmentation violation where -c0 raised the error.  It defaults to one
# now, and the amd64 string index (indc), whose check was emitted with
# its compare the wrong way round and its jumps off by one, is rewritten.
#
# Runs tests/jit_bounds_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/jit_bounds_test.dis" ] || { echo "SKIP: dis/tests/jit_bounds_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/jit_bounds_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: out-of-range indices raise array bounds error under -c$c"
	else
		echo "FAIL: out-of-range indices are not caught under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
