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
#	program (which keeps emu running);
#	under -mbook, a character none of Libertinus's fonts has (✓) is set
#	in the fallback, DejaVu Sans (DF, special), and one no font has is
#	said, once (.mg), not dropped without a word;
#	a pair kerned as the font kerns it, once: Libertinus's Latin and
#	Greek share their kerning lookups, which Neatmkfn wrote once for
#	each script and troff, with no script chosen, performed each time
#	(AV twice its kern); and a first glyph in no class of a pair's
#	class definition (class 0: D of DA), which Neatmkfn left unkerned;
#	with fontTools, every pair of letters in Libertinus Serif and Sans
#	checked against the font's GPOS.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "troff_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] || { echo "troff_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/troff.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf '.nr x 30000\n.af x i\n\\nx\n.nr y 39999\n.af y I\n\\ny\n' >"$tmp/roman.tr"
printf '.sp 5i\nword\n.pl 4i\n' >"$tmp/pl.tr"
printf 'A check ✓, and 中 and 中 again.\n' >"$tmp/fb.tr"

with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "troff < '#U*$tmp/roman.tr' > '#U*$tmp/roman.out'; troff < '#U*$tmp/pl.tr' > '#U*$tmp/pl.out'; troff -mbook < '#U*$tmp/fb.tr' > '#U*$tmp/fb.out' >[2] '#U*$tmp/fb.err'" \
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
# the fallback: ✓ set in the font mounted as DF
if python3 -c '
import re, sys
pos = None
mounts = {}
f = 0
for ln in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"x font (\d+) (\S+)", ln)
    if m:
        mounts[m.group(1)] = m.group(2)
    m = re.match(r"f(\d+)", ln)
    if m:
        f = m.group(1)
    if "c✓" in ln:
        pos = mounts.get(f)
sys.exit(0 if pos == "DF" else 1)
' "$tmp/fb.out" 2>/dev/null && [ "$(grep -c '中' "$tmp/fb.err")" = 1 ]; then
    echo "PASS: a character Libertinus lacks set in the fallback, one no font has said once"
else
    echo "FAIL: the fallback: $(grep -v '^aux' "$tmp/fb.err" | head -3)"
    fail=1
fi
# kerning, once: AV at 10 points is Libertinus Serif's -112 (thousandths
# of an em), and every pair of letters as the font's GPOS gives it
printf '.ps 10\n.ft R\nAV\n.br\n' >"$tmp/kern.tr"
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; troff kern.tr > kern.out" </dev/null >/dev/null 2>&1
if grep -q 'cAh695h-112cV' "$tmp/kern.out"; then
    echo "PASS: a pair kerned once (AV)"
else
    echo "FAIL: AV kerned $(grep -o 'cA[^c]*cV' "$tmp/kern.out")"; fail=1
fi
if python3 -c 'import fontTools' 2>/dev/null; then
    python3 -I - "$ROOT/fonts/libertinus" > "$tmp/pairs.tr" <<'PY'
import sys
# every pair of letters, a word each, after its font
caps = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
for ft, name in (('R', 'Serif-Regular'), ('HR', 'Sans-Regular')):
    print('.ft %s' % ft)
    for a in caps:
        print(' '.join(a + b for b in caps))
    print('.br')
PY
    printf '.ps 10\n.fp 6 HR\n.nf\n' | cat - "$tmp/pairs.tr" > "$tmp/pairs2.tr"
    with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; troff pairs2.tr > pairs.out" </dev/null >/dev/null 2>&1
    python3 -I - "$tmp/pairs.out" "$ROOT/fonts/libertinus" <<'PY' && echo "PASS: every pair of letters kerned as the font's GPOS kerns it" || { echo "FAIL: kerning differs from the font's: see above"; fail=1; }
import re, sys
from fontTools.ttLib import TTFont
out, d = sys.argv[1:3]
def kern(f, a, b):
    # the font's kern feature for Latin, its lookups in order, the first
    # subtable that covers the pair in each
    g = f['GPOS'].table
    cm = f.getBestCmap()
    ga, gb = cm[ord(a)], cm[ord(b)]
    ls = [s for s in g.ScriptList.ScriptRecord if s.ScriptTag == 'latn'][0].Script.DefaultLangSys
    lookups = sorted(set(i for fi in ls.FeatureIndex if g.FeatureList.FeatureRecord[fi].FeatureTag == 'kern'
                         for i in g.FeatureList.FeatureRecord[fi].Feature.LookupListIndex))
    tot = 0
    for li in lookups:
        for t in g.LookupList.Lookup[li].SubTable:
            if ga not in t.Coverage.glyphs:
                continue
            if t.Format == 1:
                ps = t.PairSet[t.Coverage.glyphs.index(ga)]
                pv = [p for p in ps.PairValueRecord if p.SecondGlyph == gb]
                if not pv:
                    continue
                v = pv[0].Value1
            else:
                c2 = t.ClassDef2.classDefs.get(gb, 0)
                v = t.Class1Record[t.ClassDef1.classDefs.get(ga, 0)].Class2Record[c2].Value1
            tot += getattr(v, 'XAdvance', 0) or 0 if v else 0
            break
    return tot
fonts = {'1': TTFont(d + '/LibertinusSerif-Regular.otf'), '6': TTFont(d + '/LibertinusSans-Regular.otf')}
bad = []
n = 0
ft = None
for ln in open(out, encoding='utf-8'):
    m = re.match(r'f(\d+)', ln)
    if m:
        ft = m.group(1)
    for a, k, b in re.findall(r'c([A-Za-z])h\d+(?:h(-?\d+))?c([A-Za-z])', ln):
        if ft not in fonts:
            continue
        n += 1
        want = kern(fonts[ft], a, b)
        if int(k or 0) != want:
            bad.append((ft, a + b, k, want))
print('%d pairs, %d kerned otherwise %s' % (n, len(bad), bad[:5]))
sys.exit(not (n > 5000 and not bad))
PY
fi
exit $fail
