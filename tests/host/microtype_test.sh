#!/bin/sh
#
# microtype_test.sh — troff's protrusion (.mtp, .mtpc) and book -f:
#
#	with .mtp 1, a justified line ending in a full stop or a hyphen
#	reaches past the right margin by 0.7 of that glyph's width (its
#	.mtpc right code, in thousandths), a line beginning with an opening
#	quotation mark starts left of the margin by half the mark's width,
#	and every other line ends at the margin;
#	codes given (.mtpc) but protrusion off (.mtp 0, the default): the
#	output is that of no codes, byte for byte (as C Neatroff's);
#	with .mte 20 20 5 (font expansion), each justified line still ends
#	at the margin, its glyphs' advances scaled by its x X mtx (within
#	±20, a multiple of 5), and some lines are expanded or condensed;
#	tr2pdf draws them scaled (Tz) where troff put them: poppler finds
#	every line's right edge at the margin (within 0.1 point; they
#	drifted 0.3 when the PDF's cursor was not tracked as troff's);
#	book -f (the book as it goes to press) sets -mbook's protrusion and
#	expansion, book without it (a draft) does neither.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "microtype_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] || { echo "microtype_test: SKIP (dis not built)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "microtype_test: SKIP (no python3)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/microtype.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

python3 -I - "$tmp" <<'PY'
import random, sys
R = random.Random(5)
w = ("the argument of virtue justice soul polis tragedy chorus dialectic philosophy first "
     "should general citizen knowledge incomprehensibilities internationalization encyclopaedia").split()
txt = []
for i in range(220):
    t = R.choice(w)
    if R.random() < .15:
        t += '.'
    if R.random() < .04:
        t = '“' + t + '”'
    txt.append(t)
body = '\n'.join(' '.join(txt[i:i + 11]) for i in range(0, len(txt), 11))
head = '.ll 3i\n.ad b\n.hy 1\n'
codes = '.mtpc R 0 700 . \\(hy\n.mtpc R 500 300 “\n'
d = sys.argv[1]
open(d + '/off.tr', 'w').write(head + body + '\n')
open(d + '/offc.tr', 'w').write(head + codes + body + '\n')
open(d + '/on.tr', 'w').write(head + codes + '.mtp 1\n' + body + '\n')
open(d + '/ex.tr', 'w').write('.mte 20 20 5\n' + head + body + '\n')
PY
cp tests/book/book.ms tests/book/works.bib "$tmp/"
cp "$tmp/book.ms" "$tmp/final.ms"

with_timeout 600 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "cd '#U*$tmp'; troff off.tr > off.out; troff offc.tr > offc.out; troff on.tr > on.out; troff ex.tr > ex.out; tr2pdf ex.out > ex.pdf; book -p works.bib book.ms; book -f -p works.bib final.ms" \
    </dev/null >"$tmp/emu.log" 2>&1

if [ -s "$tmp/off.out" ] && cmp -s "$tmp/off.out" "$tmp/offc.out"; then
    echo "PASS: codes without .mtp change nothing"
else
    echo "FAIL: codes without .mtp change the output"
    fail=1
fi

python3 -I - "$tmp/on.out" <<'PY' || fail=1
import re, sys
lines = []
for ln in open(sys.argv[1], encoding='utf-8'):
    ln = ln.rstrip('\n')
    if ln.startswith('H'):
        lines.append({'h': int(ln[1:]), 'start': None, 'text': '', 'last': 0, 'pos': int(ln[1:])})
        continue
    if ln.startswith('V') or not lines:
        continue
    cur = lines[-1]
    for m in re.finditer(r'c(.)|C(\S+)|h(-?\d+)', ln):
        if m.group(1) or m.group(2):
            if cur['start'] is None:
                cur['start'] = cur['pos']
            cur['text'] += m.group(1) or m.group(2)
            cur['last'] = None
        else:
            cur['pos'] += int(m.group(3))
            if cur['last'] is None:
                cur['last'] = int(m.group(3))	# the advance after the last glyph so far
margin = 7200 + 3 * 7200
bad = []
for l in lines[:-1]:	# the paragraph's last line is not justified
    c = l['text'][-1]
    want = margin + (700 * l['last'] // 1000 if c in '.-' else 0)
    if abs(l['pos'] - want) > 1:
        bad.append((l['text'][-12:], l['pos'], want))
q = [l for l in lines if l['text'].startswith('“')]
qbad = [(l['text'][:8], l['start']) for l in q if l['start'] >= 7200]
rest = [l for l in lines if not l['text'].startswith('“') and l['start'] != 7200]
ok = not bad and lines and any(l['text'][-1] in '.-' for l in lines[:-1])
print(('PASS' if ok else 'FAIL') + ': line ends: a full stop or hyphen 0.7 of its width past the margin, the rest at it %s' % bad[:3])
ok2 = q and not qbad and not rest
print(('PASS' if ok2 else 'FAIL') + ': an opening quotation mark left of the margin (%d lines), the rest at it %s %s' % (len(q), qbad[:2], [l['text'][:8] for l in rest[:2]]))
sys.exit(0 if ok and ok2 else 1)
PY

python3 -I - "$tmp/ex.out" "$tmp/ex.pdf" <<'PY' || fail=1
import re, subprocess, sys
lines = []
ex = 0
exs = []
for ln in open(sys.argv[1], encoding='utf-8'):
    ln = ln.rstrip('\n')
    m = re.match(r'x X mtx (-?\d+)', ln)
    if m:
        ex = int(m.group(1))
        exs.append(ex)
        continue
    if ln.startswith('H'):
        lines.append([int(ln[1:]), ''])
        continue
    if ln.startswith('V') or not lines or ln.startswith('x'):
        continue
    for m in re.finditer(r'c(.)|C(\S+)|h(-?\d+)', ln):
        if m.group(3):
            lines[-1][0] += int(m.group(3))
ends = set(l[0] for l in lines[:-1])
used = [e for e in exs if e]
ok = ends == {7200 + 3 * 7200} and used and all(abs(e) <= 20 and e % 5 == 0 for e in exs) and any(e > 0 for e in used) and any(e < 0 for e in used)
print(('PASS' if ok else 'FAIL') + ': expansion: justified lines end at the margin %s, %d lines scaled %s' % (sorted(ends)[:3], len(used), sorted(set(used))))
have = subprocess.run(['sh', '-c', 'command -v pdftotext'], capture_output=True).returncode == 0
if have:
    bb = subprocess.run(['pdftotext', '-bbox', sys.argv[2], '-'], capture_output=True, text=True).stdout
    rows = {}
    for m in re.finditer(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)"', bb):
        rows.setdefault(round(float(m.group(2))), []).append(float(m.group(3)))
    e = [max(v) for k, v in sorted(rows.items())][:-1]
    ok2 = e and max(e) - 288 < 0.1 and 288 - min(e) < 0.1
    print(('PASS' if ok2 else 'FAIL') + ': the PDF draws each expanded line to the margin (%.2f to %.2f)' % (min(e or [0]), max(e or [0])))
    ok = ok and ok2
else:
    print('SKIP: no pdftotext')
sys.exit(0 if ok else 1)
PY

if [ -s "$tmp/book.out" ] && [ -s "$tmp/final.out" ] && ! cmp -s "$tmp/book.out" "$tmp/final.out" &&
        grep -q '^x X mtx' "$tmp/final.out" && ! grep -q '^x X mtx' "$tmp/book.out"; then
    echo "PASS: book -f sets the book with protrusion and expansion, book a draft without"
else
    echo "FAIL: book -f: $(grep -v fsqid "$tmp/emu.log" | head -3)"
    fail=1
fi
exit $fail
