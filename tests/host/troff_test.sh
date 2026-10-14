#!/bin/sh
#
# troff_test.sh — troff(1), what fuzzing it against C Neatroff found:
#
#	roman numerals of 10000 to 39999 (.af x i and I) are set as C
#	Neatroff sets them (39999 is ZZZMZCMXCIX), not a
#	slice past the end of the letters for five (V) that stopped troff;
#	text already below a page length then shortened under it (.pl) is
#	set and troff ends, where it filled no lines for ever (C's
#	MIN(LEN(a), n) compares unsigned, so n < 0 is all of a);
#	where troff fails it says so and exits, not leaving a Broken
#	program (which keeps emu running).

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "troff_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] || { echo "troff_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/troff.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '.nr x 30000\n.af x i\n\\nx\n.nr y 39999\n.af y I\n\\ny\n' >"$tmp/roman.tr"
printf '.sp 5i\nword\n.pl 4i\n' >"$tmp/pl.tr"

with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "troff < '#U*$tmp/roman.tr' > '#U*$tmp/roman.out'; troff < '#U*$tmp/pl.tr' > '#U*$tmp/pl.out'" \
    </dev/null >"$tmp/emu.log" 2>&1
st=$?

r=$(grep -o 'c[a-zA-Z]' "$tmp/roman.out" 2>/dev/null | tr -d 'c\n')
if [ "$r" = "zzzZZZMZCMXCIX" ]; then
    echo "PASS: roman numerals 30000 and 39999"
else
    echo "FAIL: roman numerals 30000 and 39999: '$r' (exit $st)"
    fail=1
fi

if [ $st != 124 ] && grep -q 'cw' "$tmp/pl.out" 2>/dev/null; then
    echo "PASS: text below a page length shortened under it"
else
    echo "FAIL: text below a page length shortened under it (exit $st)"
    fail=1
fi
exit $fail
