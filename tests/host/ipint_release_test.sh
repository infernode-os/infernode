#!/bin/sh
#
# tests/host/ipint_release_test.sh
#
# IPint's long operations (expmod with a modulus over 512 bits and an
# exponent over 32, invert modulo more than 1024 bits, mul, div and mod
# of operands over 16384 bits) release the Dis VM while libmp computes,
# so other Limbo threads keep running: a 2048-bit expmod held the VM
# for 90 ms on a fast x86, seconds on a Raspberry Pi.
#
# Runs tests/ipint_release_test.b under -c0 and -c1, each of which must
# print the framework's PASS line and no crash signature; the freeze
# times it measures are printed.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/ipint_release_test.dis" ] || { echo "SKIP: dis/tests/ipint_release_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/ipint_release_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	echo "$out" | grep 'lateness' | sed "s/^/  -c$c: /"
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: IPint's long operations leave the VM to other threads under -c$c"
	else
		echo "FAIL: IPint release under -c$c:"
		echo "$out" | grep -v sdl3 | head -40
		rc=1
	fi
done
exit $rc
