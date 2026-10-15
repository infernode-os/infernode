#!/bin/sh
#
# index_test.sh — mkindex(1) and -mbook's .index and .printindex:
#
#	mkindex writes for tests/book/mkindex.out (troff's output, its
#	entries and folios as -mbook writes them) the index
#	tests/book/mkindex.ind: word by word, accents, case and troff's
#	escapes aside (New York before Newark, Ætna and ἀρετή (sorted as
#	aretē) under a, Greek after the Latin); levels; three pages in a
#	row a range, two not; a range's end abbreviated as the Manual
#	abbreviates it (101–8); front matter's roman folios; ( and )
#	ranges; a page once, bold or italic if any of its entries is;
#	See (once, however often given) and See also, after an entry's
#	subentries;
#	book sets tests/book/notes.ms with an index of its words, each
#	indexed where the word is set: every entry gives the page its word
#	is set on, in the text or in a note, a note carried over pages
#	among them; the index is the book's last page, no blank one after;
#	its last page's two columns balanced (within two lines), where the
#	first was filled before the second was begun.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "index_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/mkindex.dis" ] && [ -f "$ROOT/dis/troff.dis" ] ||
    { echo "index_test: SKIP (dis not built)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "index_test: SKIP (no python3)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/index.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# the notes' book, a word indexed before each line it begins
python3 -I - tests/book/notes.ms "$tmp/n.ms" <<'PY'
import re, sys
out = []
for l in open(sys.argv[1]).read().split('\n'):
    m = re.match(r'([kn]\d{4})\b', l)
    if m:
        out.append('.index "%s"' % m.group(1))
    out.append(l)
out.append('.printindex')
open(sys.argv[2], 'w').write('\n'.join(out))
PY

with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "mkindex /tests/book/mkindex.out > '#U*$tmp/mkindex.ind'; cd '#U*$tmp'; book n.ms" \
    </dev/null >"$tmp/emu.log" 2>&1

if cmp -s "$tmp/mkindex.ind" tests/book/mkindex.ind; then
    echo "PASS: mkindex's index"
else
    echo "FAIL: mkindex's index:"
    diff tests/book/mkindex.ind "$tmp/mkindex.ind" | head -20 | sed 's/^/    /'
    fail=1
fi

if [ ! -s "$tmp/n.out" ] || [ ! -s "$tmp/n.ind" ]; then
    echo "FAIL: no book: $(grep -v fsqid "$tmp/emu.log" | head -5)"
    exit 1
fi
python3 -I - "$tmp/n.out" "$tmp/n.ind" "$tmp/n.aux" "$tmp/n.pdf" <<'PY' || fail=1
import re, sys
out, ind, aux, pdf = sys.argv[1:5]
fail = 0
def check(ok, what):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        fail = 1
pages = []
folio = {}
cur = None
for ln in open(out, encoding='utf-8'):
    ln = ln.rstrip('\n')
    if re.fullmatch(r'p\d+', ln):
        cur = []
        pages.append(cur)
    elif ln.startswith('x X folio '):
        folio[len(pages)] = ln[len('x X folio '):]
    elif cur is not None:
        cur.append(''.join(re.findall(r'c(.)', ln)))
m = re.search(r'"Index" (\d+)', open(aux).read())
check(m is not None, 'the index is in the contents')
start = int(m.group(1)) if m else 10**9
where = {}
for i, p in enumerate(pages):
    f = folio.get(i + 1)
    if f and f.isdigit() and int(f) >= start:
        continue
    for w in re.findall(r'[kn]\d{4}', ''.join(p)):
        where.setdefault(w, set()).add(f)
# each page a link to it (mkindex -l, as book runs it): its folio and
# what is shown
links = re.findall(r'\\\*\[book-pl (\S+) (\S+)\]', open(ind, encoding='utf-8').read())
check(len(links) > 60 and all(f == t for f, t in links),
    'each page in the index a link to its page (%d)' % len(links))
plain = lambda l: re.sub(r'\\\*\[book-pl \S+ (\S+)\]', r'\1', l)
entries = [re.match(r'([kn]\d{4}), (.*)', plain(l)) for l in open(ind, encoding='utf-8')]
entries = [e for e in entries if e]
wrong = [(e.group(1), e.group(2), sorted(where.get(e.group(1), []))) for e in entries
    if set(e.group(2).strip().split(', ')) != where.get(e.group(1))]
notes = sum(1 for e in entries if e.group(1)[0] == 'n')
check(len(entries) > 60 and notes > 20 and not wrong,
    'each entry gives its word\'s page (%d entries, %d in notes) %s' % (len(entries), notes, wrong[:3]))
last = ''.join(pages[-1]) if pages else ''
check(re.search(r'[kn]\d{4}', last) is not None, 'the index ends the book, no blank page after it')
# the last page's columns, by their lines' places in troff's output
cols = {}
h = 0
v = 0
for ln in ''.join(open(out, encoding='utf-8').read().split('\np')[-1:]).split('\n'):
    for cmd in re.finditer(r'([HVhv])(-?\d+)|c(.)', ln):
        if cmd.group(1) == 'H':
            h = int(cmd.group(2))
        elif cmd.group(1) == 'h':
            h += int(cmd.group(2))
        elif cmd.group(1) == 'V':
            v = int(cmd.group(2))
        elif cmd.group(1) == 'v':
            v += int(cmd.group(2))
        elif re.match(r'[kn]', cmd.group(3) or ''):
            cols.setdefault(0 if h < 20000 else 1, set()).add(v)
n0, n1 = len(cols.get(0, ())), len(cols.get(1, ()))
check(n0 + n1 > 4 and n1 > 0 and abs(n0 - n1) <= 2, "the last page's columns balanced (%d and %d lines)" % (n0, n1))
sys.exit(fail)
PY
exit $fail
