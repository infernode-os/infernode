#!/bin/sh
#
# tests/host/devip_conv_test.sh
#
# The hosted emulator's /net conversations (emu/port/devip.c), through
# tests/devip_conv_test.b in an emulator limited to 256 descriptors, so
# that sockets run out before conversations do: a clone, or the first
# open of a conversation's ctl, refused for want of a socket loses no
# conversation (each lost one for good: locked and in use, or in use);
# the table grows while another Prog lists it; a user opens their own
# conversations and not another's (the owner's permission bits were
# asked whoever the user was).
#
# Skips (exit 77) when there is no emulator or the program is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/devip_conv_test.dis" ] || { echo "SKIP: dis/tests/devip_conv_test.dis not built"; exit 77; }
( ulimit -n 256 ) 2>/dev/null || { echo "SKIP: the descriptor limit cannot be set"; exit 77; }

TIMEOUT=${TIMEOUT:-240}
rc=0
for c in 1 0; do
	out=$( ulimit -n 256; with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/devip_conv_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null )
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|--- SKIP\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: -c$c: no conversation lost to a refused socket; a user's conversations their own"
	else
		echo "FAIL: -c$c: devip conversations:"
		echo "$out" | grep -v sdl3 | tail -25
		rc=1
	fi
done
exit $rc
