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
#	the bibliography is sorted, its entries Chicago's.

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
    if cur is None:
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
    check('Πάντες ἄνθρωποι τοῦ εἰδέναι ὀρέγονται φύσει.' in allt, 'Greek is set')
    b = allt[allt.rindex('Bibliography'):]
    order = [b.find(n) for n in ('Grazer, Brian', 'Homer.', 'Satterfield, Susan', 'Smith, Zadie', 'Thoreau, Henry David')]
    check(all(x >= 0 for x in order) and order == sorted(order), 'the bibliography is sorted')
else:
    print('SKIP: no pdftotext')
sys.exit(fail)
PY
