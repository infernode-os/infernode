#!/bin/sh
#
# tests/host/utf21_test.sh
#
# Runes beyond the Basic Multilingual Plane (U+10000 to U+10FFFF:
# emoji, CJK extension B, mathematical alphanumerics) are one rune
# each, in and out of Limbo strings, from compiled code as from the
# interpreter.
#
# A rune was 16 bits on hosted platforms and lib9's chartorune
# decoded at most three bytes, so the four bytes of U+1F680 became
# error runes and came back out as C2 80s. The amd64 JIT's s[i] on a
# rune string loaded 16 bits, so it is run under -c1 as well as -c0.
#
# Runs tests/utf21_test.b under -c0 and -c1, each of which must print
# the framework's PASS line and no crash signature.
#
# Skips (exit 77) when there is no emulator or the test is not built.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/utf21_test.dis" ] || { echo "SKIP: dis/tests/utf21_test.dis not built"; exit 77; }

TIMEOUT=${TIMEOUT:-120}
rc=0
for c in 0 1; do
	out=$(with_timeout "$TIMEOUT" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/utf21_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:'; then
		echo "PASS: runes beyond U+FFFF round-trip under -c$c"
	else
		echo "FAIL: runes beyond U+FFFF do not round-trip under -c$c:"
		echo "$out" | grep -v sdl3 | head -30
		rc=1
	fi
done
exit $rc
