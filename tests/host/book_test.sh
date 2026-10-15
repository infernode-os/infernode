#!/bin/sh
#
# book_test.sh — book(1) and troff's macros -mbook: tests/book/book.ms,
# a short book (title page, contents, preface, three chapters with
# sections, an epigraph, block quotations, footnotes of its own and
# refer's Chicago notes, endnotes, cross-references, a bibliography),
# set to PDF, then checked:
#
#	its pages are 6 by 9 inches;
#	the table of contents gives each chapter the page it opens on (the
#	passes book(1) makes until the references settle), and so do the
#	cross-references (\*[ref ch2], \*[pageref ch2]);
#	chapters open on right-hand pages, a blank page before if need be,
#	without a running head and with the folio at the foot; other
#	pages have the running heads: the book's title on the left, the
#	chapter's on the right;
#	no line of the text is set below a page's footnotes, and a note
#	citing a work is on the page of its mark;
#	Greek is set and hyphenated as Greek;
#	the bibliography is sorted, its entries Chicago's;
#	the contents' page numbers end at one right edge (a section's,
#	indented, did not), their leaders' dots on one grid (they began
#	wherever the leader did);
#	with twelve endnotes in a chapter, the notes' numbers right-aligned
#	and their text at one indent (10. began its text further right
#	than 9.), a chapter's heading in the notes never the last line of a
#	page (its .ne was spent while the notes were gathered); the
#	bibliography, set ragged, not hyphenated.
#
# Then tests/book/notes.ms, notes short, long and longer than a page,
# its words kNNNN (the text) and nNNNN (the notes) each to be set once:
#
#	every word is set, once: a note longer than the page's room goes
#	on on the next pages (where troff looped, the foot's trap carrying
#	the whole note on each), and the text with it;
#	no note is set below the bottom margin (the rule set as a line of
#	its own, and the room for it, were a line short), nor any text;
#	no text is set over the notes (troff sets the line that reaches a
#	trap before springing it: the trap is a line above them).

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "book_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] && [ -f "$ROOT/dis/tr2pdf.dis" ] && [ -f "$ROOT/dis/refer.dis" ] ||
    { echo "book_test: SKIP (dis not built)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "book_test: SKIP (no python3)"; exit 77; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/book.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp tests/book/book.ms tests/book/works.bib "$tmp/"

with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; book -p works.bib book.ms" </dev/null >"$tmp/emu.log" 2>&1
if [ ! -s "$tmp/book.pdf" ] || [ ! -s "$tmp/book.out" ]; then
    echo "FAIL: no book: $(grep -v fsqid "$tmp/emu.log" | head -5)"
    exit 1
fi

python3 -I - "$tmp/book.out" "$tmp/book.pdf" <<'PY'
import re, subprocess, sys
out, pdf = sys.argv[1], sys.argv[2]
fail = 0
def check(ok, what):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        fail = 1

# troff's output, a page at a time: the text of each line, its size and place
pages = []
cur = None
size = 0
v = 0
line = None
for ln in open(out, encoding='utf-8'):
    ln = ln.rstrip('\n')
    if ln.startswith('p') and ln[1:].isdigit():
        cur = {'lines': [], 'rule': None}
        pages.append(cur)
        continue
    if cur is None or ln.startswith('x '):	# device control: no text, no motion
        continue
    for cmd in re.finditer(r'([sVHvh])(-?\d+)|c(.)|D(l) (-?\d+) (-?\d+)|C(\S+)', ln):
        if cmd.group(1) == 's':
            size = int(cmd.group(2))
        elif cmd.group(1) == 'V':
            v = int(cmd.group(2))
            line = None
        elif cmd.group(1) == 'v':
            v += int(cmd.group(2))
        elif cmd.group(4):
            if cur['rule'] is None:
                cur['rule'] = v
        elif cmd.group(3) or cmd.group(7):
            if line is None or line[0] != v:
                line = [v, size, '']
                cur['lines'].append(line)
            line[2] += cmd.group(3) or ''

def text(p):
    return subprocess.run(['pdftotext', '-layout', '-f', str(p), '-l', str(p), pdf, '-'],
        capture_output=True, text=True).stdout if have_poppler else ''
have_poppler = subprocess.run(['sh', '-c', 'command -v pdftotext'], capture_output=True).returncode == 0

# the page's size
size = open(pdf, 'rb').read().split(b'/MediaBox [ 0 0 ')[1].split(b']')[0].split()
check(size == [b'432', b'648'], 'the pages are 6 by 9 inches (%s)' % b' '.join(size).decode())

# where each chapter opens, by its heading "Chapter N", and its folio
opens = {}
for i, p in enumerate(pages):
    for l in p['lines']:
        m = re.fullmatch(r'Chapter(\d)', l[2])
        if m:
            opens[m.group(1)] = i + 1
check(sorted(opens) == ['1', '2', '3'], 'three chapters (%s)' % sorted(opens))
check(all(n % 2 == 1 for n in opens.values()), 'chapters open on right-hand pages (%s)' % opens)

# the contents: "1. On Virtue....1"; the main matter's page 1 is the first chapter's
first = opens.get('1', 0)
toc = {}
for l in pages[2]['lines']:
    m = re.match(r'(\d)\.On\w+\.+(\d+)$', l[2].replace(' ', ''))
    if m:
        toc[m.group(1)] = int(m.group(2))
check(toc and all(opens[k] - first + 1 == toc[k] for k in toc),
    'the contents give each chapter its page (%s, opening at %s)' % (toc, opens))

# no text below a page's footnotes: the text's size is 11, the notes' 9
bad = []
for i, p in enumerate(pages):
    if p['rule'] is None:
        continue
    for l in p['lines']:
        if l[0] > p['rule'] and l[1] == 11:
            bad.append((i + 1, l[2][:20]))
check(not bad, 'no text below the footnotes %s' % bad[:3])

# a full note on chapter 1's first page, where it is cited
p = pages[first - 1]
notes = ''.join(l[2] for l in p['lines'] if l[1] == 9)
check('ZadieSmith,' in notes and 'SwingTime' in notes, 'a citing note on the page of its mark')

if have_poppler:
    t = text(first + 1)
    check('A Study of Virtue' in t.split('\n')[0] or 'A Study of Virtue' in t[:200], "the book's title heads a left-hand page")
    t = text(first + 2)
    check('On Virtue' in t[:200], "the chapter's title heads a right-hand page")
    t = text(first)
    check('A Study of Virtue' not in t[:200], 'no running head on a chapter\'s first page')
    allt = subprocess.run(['pdftotext', pdf, '-'], capture_output=True, text=True).stdout
    check('see chapter 2 on page %d' % (opens['2'] - first + 1) in ' '.join(allt.split()),
        'a cross-reference gives the chapter and its page')
    # the contents (page 3): numbers right-aligned, dots in step
    import xml.etree.ElementTree as ET
    bb = subprocess.run(['pdftotext', '-bbox', '-f', '3', '-l', '3', pdf, '-'],
        capture_output=True, text=True).stdout
    words = [(float(w.get('xMin')), float(w.get('xMax')), round(float(w.get('yMin'))), w.text or '')
        for w in ET.fromstring(bb[bb.index('<html'):].replace('xmlns="http://www.w3.org/1999/xhtml"', '')).iter('word')]
    nums = [w for w in words if re.fullmatch(r'\d+|[ivxl]+', w[3]) and w[0] > 300]
    ends = set(round(w[1]) for w in nums)
    check(len(nums) >= 8 and len(ends) == 1, 'the contents\' page numbers end at one edge %s' % sorted(ends))
    # each line's dots end at the same stop, so lie on one grid
    rows = {}
    for w in words:
        if w[3] == '.':
            rows.setdefault(w[2], []).append(w[0])
    last = [max(xs) for xs in rows.values() if len(xs) > 3]
    check(len(last) >= 8 and max(last) - min(last) < 0.25,
        "the leaders' dots in step (%d lines, their last dots %.2f to %.2f)" % (len(last), min(last or [0]), max(last or [0])))
    check('Πάντες ἄνθρωποι τοῦ εἰδέναι ὀρέγονται φύσει.' in allt, 'Greek is set')
    b = allt[allt.rindex('Bibliography'):]
    order = [b.find(n) for n in ('Grazer, Brian', 'Homer.', 'Satterfield, Susan', 'Smith, Zadie', 'Thoreau, Henry David')]
    check(all(x >= 0 for x in order) and order == sorted(order), 'the bibliography is sorted')
else:
    print('SKIP: no pdftotext')
sys.exit(fail)
PY
st=$?

# endnotes past nine, the bibliography
python3 -I - "$tmp/book.ms" "$tmp/en.ms" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.index('.en\n')
add = ''.join('word\\c\n.en\nAn endnote, the %dth, long enough to run over a line: with Greek, '
    'μῆνιν ἄειδε θεά, and more words to wrap.\n.ee\n' % (k + 3) for k in range(10))
open(sys.argv[2], 'w').write(s[:i] + add + s[i:])
PY
with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; book -p works.bib en.ms" </dev/null >"$tmp/emu3.log" 2>&1
if command -v pdftotext >/dev/null 2>&1; then
python3 -I - "$tmp/en.pdf" <<'PY' || st=1
import re, subprocess, sys
pdf = sys.argv[1]
n = int(re.search(r'Pages:\s+(\d+)', subprocess.run(['pdfinfo', pdf], capture_output=True, text=True).stdout).group(1))
fail = 0
def check(ok, what):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        fail = 1
def words(p):
    bb = subprocess.run(['pdftotext', '-bbox', '-f', str(p), '-l', str(p), pdf, '-'], capture_output=True, text=True).stdout
    return [(float(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4))
        for m in re.finditer(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="[\d.]+">([^<]*)<', bb)]
notes = [p for p in range(1, n + 1) if any(w[3] == 'Notes' for w in words(p)[:2])]
bib = [p for p in range(1, n + 1) if any(w[3] == 'Bibliography' for w in words(p)[:2])]
starts = {}
headlast = []
for p in range(notes[0] if notes else 1, bib[0] if bib else 1):
    ws = words(p)
    rows = {}
    for w in ws:
        rows.setdefault(round(w[1]), []).append(w)
    for y, r in rows.items():
        r.sort()
        if re.fullmatch(r'\d+\.', r[0][3]) and len(r) > 1:
            starts.setdefault(p, set()).add(round(r[1][0], 1))
    body = [r for y, r in sorted(rows.items()) if not (len(r) == 1 and re.fullmatch(r'\d+', r[0][3]))]
    if body and sorted(body[-1])[0][3] == 'Chapter':
        headlast.append(p)
check(notes and starts and all(len(v) == 1 for v in starts.values()),
    "the endnotes' text at one indent on each page, past numbers of one and two digits %s" % starts)
check(notes and not headlast, "no chapter's heading the last line of a page of notes %s" % headlast)
hy = []
for p in bib:
    rows = {}
    for w in words(p):
        rows.setdefault(round(w[1]), []).append(w)
    hy += [max(r)[3] for r in rows.values() if max(r)[3].endswith('-') and len(max(r)[3]) > 1]
check(bib and not hy, 'the bibliography not hyphenated %s' % hy)
sys.exit(fail)
PY
fi

cp tests/book/notes.ms "$tmp/"
with_timeout 300 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; book notes.ms" </dev/null >"$tmp/emu2.log" 2>&1
if [ ! -s "$tmp/notes.out" ]; then
    echo "FAIL: no notes.out: $(grep -v fsqid "$tmp/emu2.log" | head -5)"
    exit 1
fi
python3 -I - "$tmp/notes.out" tests/book/notes.ms <<'PY' || st=1
import re, sys
out, src = sys.argv[1], sys.argv[2]
fail = 0
def check(ok, what):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what)
    if not ok:
        fail = 1
words = re.findall(r'\b[kn]\d{4}\b', open(src).read())
res = 7200
pages = []
cur = None
v = 0
line = None
for ln in open(out, encoding='utf-8'):
    ln = ln.rstrip('\n')
    m = re.match(r'x res (\d+)', ln)
    if m:
        res = int(m.group(1))
    if re.fullmatch(r'p\d+', ln):
        cur = {'lines': [], 'rule': None}
        pages.append(cur)
        line = None
        continue
    if cur is None:
        continue
    for cmd in re.finditer(r'([Vv])(-?\d+)|c(.)|D(l) (-?\d+) (-?\d+)', ln):
        if cmd.group(1) == 'V':
            v = int(cmd.group(2)); line = None
        elif cmd.group(1) == 'v':
            v += int(cmd.group(2)); line = None
        elif cmd.group(4):
            # the notes' rule: 1.5i, flat
            if int(cmd.group(6)) == 0 and abs(int(cmd.group(5)) - int(1.5 * res)) < 5 and cur['rule'] is None:
                cur['rule'] = v
        else:
            if line is None or line[0] != v:
                line = [v, '']
                cur['lines'].append(line)
            line[1] += cmd.group(3)
foot = 9 * res - int(0.875 * res)	# the bottom margin's top
seen = {}
below = []
over = []
for i, p in enumerate(pages):
    for v, t in p['lines']:
        for w in re.findall(r'[kn]\d{4}', t):
            seen[w] = seen.get(w, 0) + 1
            if v > foot:
                below.append((i + 1, w, v))
            if w[0] == 'k' and p['rule'] is not None and v > p['rule']:
                over.append((i + 1, w, v, p['rule']))
            if w[0] == 'n' and (p['rule'] is None or v < p['rule']):
                over.append((i + 1, w, v, p['rule']))
lost = [w for w in words if seen.get(w, 0) != 1]
check(not lost, 'every word set once (%d words, %d pages) %s' % (len(words), len(pages), lost[:4]))
check(not below, 'nothing below the bottom margin %s' % below[:3])
check(not over, 'no text over the notes, no note above their rule %s' % over[:3])
sys.exit(fail)
PY
exit $st
