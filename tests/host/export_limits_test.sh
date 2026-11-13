#!/bin/sh
#
# tests/host/export_limits_test.sh
#
# export(2)'s 9P server holds one connection to a number of fids and of
# requests not yet answered (exportfs.c's Maxfids, Maxreqs): runs
# tests/export_limits.b, which attaches past the first and sends reads of
# a file that never answers past the second, in an emulator of its own
# (it leaves a thousand slave processes behind).  Once: the limits are the
# kernel's C, the same under the interpreter and the JIT, and thirty
# thousand attaches take most of a minute.
# Before, nothing was counted: a peer chose how many Chans, request
# buffers and processes an export kept.
#
# Skips (exit 77) when there is no emulator or the program is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/export_limits.dis" ] || { echo "SKIP: dis/tests/export_limits.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-240}
rc=0
for c in 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/export_limits.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: an export holds a connection to its limits of fids and requests"
	else
		echo "FAIL: export limits:"
		echo "$out" | grep -v sdl3 | tail -25
		rc=1
	fi
done
exit $rc
