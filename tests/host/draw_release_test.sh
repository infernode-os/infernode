#!/bin/sh
#
# tests/host/draw_release_test.sh
#
# Drawing lets the VM go while devdraw draws.
#
# A local display's buffer was guarded by the Dis VM alone, so the write
# that hands it to /dev/draw held the VM: a ticker beside a Prog filling
# an 800x600 image was 3 s late on the Jetson under -c0, and drawbench
# froze a Pi Zero 2 W's VM 0, with the card's file server in it, for
# 4.7 s at a time.  Runs tests/draw_release_test.b under -c0 and -c1 on
# the SDL dummy display; each must print the framework's PASS line with
# nothing skipped and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/draw_release_test.dis" ] || { echo "SKIP: dis/tests/draw_release_test.dis not built"; exit 77; }
mkdir -p "$ROOT/tmp"

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(SDL_VIDEODRIVER=dummy with_timeout "$TIMEOUT" "$EMU" -c$c -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
		/dis/sh.dis -c "bind -a '#i' /dev; /dis/tests/draw_release_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && echo "$out" | grep -q '^2 passed$' &&
	   ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|STUCK'; then
		echo "PASS: drawing lets the VM go under -c$c"
		echo "$out" | grep 'worst ticker lateness' | sed 's/^/    /'
	elif echo "$out" | grep -q 'no display'; then
		echo "SKIP: no display under -c$c (a headless emulator)"
		[ $rc = 0 ] && rc=77
	else
		echo "FAIL: drawing kept the VM, or drew wrong, under -c$c:"
		echo "$out" | grep -v sdl3 | head -20
		rc=1
	fi
done
exit $rc
