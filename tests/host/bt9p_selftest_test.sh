#!/bin/sh
#
# tests/host/bt9p_selftest_test.sh
#
# bt9p(4)'s limits on what a radio in range can make it keep, checked
# with no radio (bt9p -S): a device's name goes into a scan's line with
# its control characters replaced, so a line break in a name is not a
# second device's line; the table of address types holds a bounded
# number however many addresses are heard, the newest among them; the
# keys file has room for so many keys and bytes and no more.
#
# Run under -c0 and -c1; "selftest OK" and no crash signature is a pass.
# Skips (exit 77) when there is no emulator or bt9p is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/bt9p.dis" ] || { echo "SKIP: dis/bt9p.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-60}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "bt9p -S; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^bt9p: selftest OK" &&
	   ! echo "$out" | grep -q 'selftest FAILED\|SEGV: addr=\|BUS: addr=\|panic:\|Broken:'; then
		echo "PASS: bt9p -S under -c$c"
	else
		echo "FAIL: bt9p -S under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
