#!/bin/sh
#
# tests/host/file2chan_close_test.sh
#
# A file2chan server is told of every close, and the kernel says nothing
# on the console about it: runs tests/file2chan_close_test.b and
# tests/hostplumb_test.b under -c0 and -c1.  A close's notice was sent
# only if the server's channel had room at that moment and otherwise
# dropped, with "csendalt failed" printed: the first test's servers were
# told of sixteen closes in two hundred, and the plumber, which never
# receives on its read channel, had the message printed at every close
# after the sixteenth (sixteen times in hostplumb_test).
#
# Skips (exit 77) when there is no emulator or the tests are not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for t in file2chan_close_test hostplumb_test; do
	[ -f "$ROOT/dis/tests/$t.dis" ] || { echo "SKIP: dis/tests/$t.dis not built"; exit 77; }
done

TIMEOUT=${TIMEOUT:-120}
rc=0
for t in file2chan_close_test hostplumb_test; do
	for c in 0 1; do
		out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/$t.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
		if ! echo "$out" | grep -q "^PASS$" || echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
			echo "FAIL: $t under -c$c:"
			echo "$out" | grep -v sdl3 | head -20
			rc=1
		elif echo "$out" | grep -q 'csendalt failed\|no room to tell a server'; then
			echo "FAIL: $t under -c$c: a close's notice was dropped ($(echo "$out" | grep -c 'csendalt failed') times)"
			rc=1
		else
			echo "PASS: $t under -c$c: every close told, nothing on the console"
		fi
	done
done
exit $rc
