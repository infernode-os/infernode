#!/bin/sh
#
# widows_test.sh — troff's widows and orphans (.wo), as -mbook sets them:
#
#	400 paragraphs of 1 to 10 lines, some with notes, some with space
#	between, every word of each its own id (q0001 ...), so that each
#	line shows its paragraph:
#	set with -mbook (.wo 1), no paragraph has its first line alone at
#	a page's foot (an orphan) or its last alone at the next page's
#	head (a widow), where with .wo 0 a dozen do;
#	every line set (as many as with .wo 0), nothing below the foot,
#	and the pages within a few of .wo 0's.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "widows_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] || { echo "widows_test: SKIP (dis not built)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "widows_test: SKIP (no python3)"; exit 77; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/widows.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

python3 -I - "$tmp" <<'PY'
import random, sys
R = random.Random(3)
L = ['.chapter "Widows" w']
for p in range(1, 400):
    n = R.choice([3, 5, 8, 12, 15, 20, 25, 30, 40, 60, 80, 100])
    L.append('')
    words = ['q%04d' % p] * n
    lines = [' '.join(words[i:i + 10]) for i in range(0, n, 10)]
    for i, l in enumerate(lines):
        if i == len(lines) // 2 and R.random() < .1:
            L.append(l + '\\c')
            L.append('.fn')
            L.append('A note to paragraph %d, long enough to take a line or two of the foot of its page.' % p)
            L.append('.fe')
        else:
            L.append(l)
    if R.random() < .05:
        L.append('.sp 2')
body = '\n'.join(L) + '\n'
open(sys.argv[1] + '/on.ms', 'w').write(body)
# .wo 0 after -mbook's begin (a paragraph's blank line begins it)
open(sys.argv[1] + '/off.ms', 'w').write(body.replace('.chapter "Widows" w\n', '.chapter "Widows" w\n.wo 0\n', 1))
PY

with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "cd '#U*$tmp'; troff -mbook on.ms > on.out >[2] /dev/null; troff -mbook off.ms > off.out >[2] /dev/null" \
    </dev/null >"$tmp/emu.log" 2>&1

python3 -I - "$tmp/on.out" "$tmp/off.out" <<'PY'
import re, sys
def read(f):
    pages = []
    cur = None
    v = 0
    below = 0
    for ln in open(f, encoding='utf-8'):
        ln = ln.rstrip('\n')
        if re.fullmatch(r'p\d+', ln):
            cur = {}
            pages.append(cur)
            continue
        m = re.match(r'V(\d+)', ln)
        if m:
            v = int(m.group(1))
            continue
        if cur is None:
            continue
        for q in re.findall(r'q(\d{4})', ''.join(re.findall(r'c(.)', ln))):
            cur.setdefault(int(q), set()).add(v)
            if v > 9 * 7200 - int(0.875 * 7200):
                below += 1
    paras = {}
    for i, p in enumerate(pages):
        for q, vs in p.items():
            paras.setdefault(q, []).append(len(vs))
    wid = [q for q, l in paras.items() if len(l) > 1 and l[-1] == 1]
    orph = [q for q, l in paras.items() if len(l) > 1 and l[0] == 1]
    lines = sum(sum(l) for l in paras.values())
    return len(pages), wid, orph, lines, below
pon, won, oon, lon, bon = read(sys.argv[1])
poff, woff, ooff, loff, boff = read(sys.argv[2])
fail = 0
def check(ok, what):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        fail = 1
check(len(woff) + len(ooff) > 5, 'with .wo 0 there are widows and orphans to avoid (%d and %d)' % (len(woff), len(ooff)))
check(not won and not oon, 'with .wo 1 no widow and no orphan %s %s' % (won[:3], oon[:3]))
check(lon == loff and lon > 1000, 'every line set (%d, %d with .wo 0)' % (lon, loff))
check(bon == 0, 'nothing below the foot (%d lines)' % bon)
check(poff <= pon <= poff * 1.1 + 1, 'pages %d, %d with .wo 0' % (pon, poff))
sys.exit(fail)
PY
