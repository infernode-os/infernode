#!/bin/sh
#
# booklinks_test.sh — a book's PDF as one is read on a screen: book(1)
# on tests/book/book.ms, with an index:
#
#	every link within the book reaches a destination in it;
#	the bookmarks are the contents: parts, chapters and sections, each
#	under the one it is in, each going to the page its heading is on;
#	each line of the contents a link, across the line, to its heading,
#	on the page the line gives;
#	a footnote's mark a link to its note, on the mark's page (or the
#	next, carried whole), the note's number one back to the mark; the
#	same for endnotes;
#	\*[ref name] and \*[pageref name] links to the label, on the page
#	pageref gives;
#	each page in the index a link to the page it gives;
#	the pages labelled as they are numbered: i, ii, ... in the front
#	matter, 1, 2, ... after;
#	the title and author in the PDF's information.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "booklinks_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] && [ -f "$ROOT/dis/tr2pdf.dis" ] && [ -f "$ROOT/dis/mkindex.dis" ] ||
    { echo "booklinks_test: SKIP (dis not built)"; exit 77; }
python3 -c 'import pypdf' 2>/dev/null || { echo "booklinks_test: SKIP (no pypdf)"; exit 77; }
command -v pdftotext >/dev/null 2>&1 || { echo "booklinks_test: SKIP (no pdftotext)"; exit 77; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/booklinks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# the book, a few words indexed and the index after the bibliography
python3 -I - tests/book/book.ms "$tmp/b.ms" <<'PY'
import sys
out = []
for i, l in enumerate(open(sys.argv[1], encoding='utf-8').read().split('\n')):
    out.append(l)
    if l.startswith('.cite smith-swing'):
        out.append('.index "Smith, Zadie"')
    if l.startswith('.section'):
        out.append('.index "sections!%s"' % l.split('"')[1])
out.append('.printindex')
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY
cp tests/book/works.bib "$tmp/"
with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; book -p works.bib b.ms" </dev/null >/dev/null 2>"$tmp/err"
if [ ! -s "$tmp/b.pdf" ]; then
    echo "FAIL: no PDF: $(cat "$tmp/err")"
    exit 1
fi
pdftotext -bbox "$tmp/b.pdf" "$tmp/b.html" 2>/dev/null

python3 -I - "$tmp/b.pdf" "$tmp/b.html" "$tmp/b.aux" "$tmp/b.out" <<'PY'
import sys, re, html, collections
import pypdf
pdf, bbox, aux, out = sys.argv[1:5]
fail = 0
def check(ok, what, why=''):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what + ('' if ok else ': ' + str(why)[:400]))
    fail |= not ok

r = pypdf.PdfReader(pdf)
labels = r.page_labels
# each page's words: (x0, top, x1, bottom, word), y down
pages = []
for m in re.finditer(r'<page width="[\d.]+" height="([\d.]+)">(.*?)</page>', open(bbox, encoding='utf-8').read(), re.S):
    pages.append((float(m.group(1)), [(float(a), float(b), float(c), float(d), html.unescape(w)) for a, b, c, d, w in
        re.findall(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)<', m.group(2))]))
dests = {}
for k, v in r.named_destinations.items():
    dests[k.lstrip('/')] = (r.get_destination_page_number(v), float(v.top))
def below(name, n=8):
    # the words in the line or two below a destination's top
    p, top = dests[name]
    h, ws = pages[p]
    return [w[4] for w in sorted((w for w in ws if h - top - 1 <= w[1] <= h - top + 28), key=lambda w: (round(w[1]), w[0]))][:n]
links = []
for i, p in enumerate(r.pages):
    h, ws = pages[i]
    for a in p.get('/Annots') or []:
        a = a.get_object()
        if a['/A']['/S'] != '/GoTo':
            continue
        x0, y0, x1, y1 = [float(v) for v in a['/Rect']]
        top, bot = h - max(y0, y1), h - min(y0, y1)
        cov = [w[4] for w in ws if min(x0, x1) - 0.5 <= (w[0] + w[2]) / 2 <= max(x0, x1) + 0.5 and top <= (w[1] + w[3]) / 2 <= bot]
        links.append((i, str(a['/A']['/D']).lstrip('/'), cov, (min(x0, x1), max(x0, x1))))

# every link reaches a destination
bad = [l[1] for l in links if l[1] not in dests]
check(len(links) >= 90 and not bad, 'every link within the book reaches a destination (%d links)' % len(links), bad[:5])

# the pages labelled as numbered: roman, then arabic from 1
front = [l for l in labels if not l.isdigit()]
body = [l for l in labels if l.isdigit()]
check(front and all(re.fullmatch('[ivxlc]+', l) for l in front) and labels[:len(front)] == front and
      body == [str(i) for i in range(1, len(body) + 1)],
      'pages labelled as numbered (%s ... %s)' % (' '.join(labels[:3]), ' '.join(labels[-2:])), labels)

# the bookmarks: the headings, nested, each on its heading's page
def walk(o, d, acc):
    for x in o:
        if isinstance(x, list):
            walk(x, d + 1, acc)
        else:
            acc.append((d, x.title, r.get_destination_page_number(x)))
    return acc
marks = walk(r.outline, 0, [])
titles = [(d, t) for d, t, p in marks]
want = [(0, 'Contents'), (0, 'Preface'), (0, '1 On Virtue'), (1, '1.1 The Argument of the Good'),
        (1, '1.2 The Problem of the Soul'), (0, '2 On Justice')]
onpage = all(t.split(' ', 1)[-1].split()[0] in [w[4] for w in pages[p][1]] for d, t, p in marks)
check(titles[:6] == want and titles[-1] == (0, 'Index') and onpage,
      'bookmarks: the headings, nested, each to its page (%d)' % len(marks), titles)

# the contents' lines: links across the line, to the page each gives
toc = [l for l in links if l[1].startswith('book-h')]
wrong = [(l[2], labels[dests[l[1]][0]]) for l in toc if not l[2] or l[2][-1] != labels[dests[l[1]][0]]]
wide = all(l[3][1] - l[3][0] > 250 for l in toc)
check(len(toc) >= 13 and not wrong and wide, 'each line of the contents a link to its heading, on the page it gives (%d)' % len(toc), wrong[:3])

# footnotes: the mark a link to the note, on the mark's page or the next; back again
fn = [l for l in links if re.fullmatch(r'fn-\d+', l[1])]
back = {l[1][4:]: l for l in links if re.fullmatch(r'fnm-\d+', l[1])}
wrong = []
for i, d, cov, _ in fn:
    n = d[3:]
    p, _ = dests[d]
    num = cov[0] if cov else None
    if not (0 <= p - i <= 1) or not num or below(d)[:1] != [num] or n not in back:
        wrong.append((d, i, p, cov, below(d)[:3]))
check(len(fn) >= 27 and not wrong, "each footnote's mark a link to its note, the note's number back (%d)" % len(fn), wrong[:3])
en = [l for l in links if re.fullmatch(r'en-\d+', l[1])]
wrong = [(d, below(d)[:2], cov) for i, d, cov, _ in en if not cov or below(d)[:1] != [cov[0] + '.']]
check(len(en) == 6 and not wrong and len([l for l in links if l[1].startswith('enm-')]) == 6,
      "each endnote's mark a link to it, and back", wrong[:3])

# references: to the label, on the page pageref gives
pageref = dict(re.findall(r'\.ds pageref-(\S+) (\S+)', open(aux, encoding='utf-8').read()))
refs = [l for l in links if l[1].startswith('lab-')]
wrong = [(l[1], l[2], labels[dests[l[1]][0]]) for l in refs if labels[dests[l[1]][0]] != pageref[l[1][4:]] or not l[2]]
pr = [l for l in refs if l[2] and l[2][0].rstrip('.') == pageref[l[1][4:]]]
check(len(refs) >= 6 and pr and not wrong, 'references link to their labels, on the pages pageref gives (%d)' % len(refs), wrong[:3])

# the index: each page a link to it
ix = [l for l in links if l[1].startswith('pg-')]
wrong = [(l[1], l[2], labels[dests[l[1]][0]]) for l in ix if not l[2] or l[2][0].rstrip(',') != l[1][3:] or labels[dests[l[1]][0]] != l[1][3:]]
check(len(ix) >= 8 and not wrong, 'each page in the index a link to it (%d)' % len(ix), wrong[:3])

# the information
info = r.metadata
check(info.title == 'A Study of Virtue' and info.author == 'An Author', 'the title and author in its information', info)

# notes on their marks' pages, from troff's output
pg = 0; mk = {}; nt = {}
for l in open(out, errors='replace'):
    if re.fullmatch(r'p\d+\n', l):
        pg = int(l[1:])
    m = re.match(r'x X dest (fnm?)-(\d+)', l)
    if m:
        (mk if m.group(1) == 'fnm' else nt).setdefault(int(m.group(2)), pg)
wrong = [k for k in mk if not 0 <= nt.get(k, -9) - mk[k] <= 1]
check(len(mk) >= 27 and not wrong, "every note on its mark's page or the next", wrong)
sys.exit(fail)
PY
