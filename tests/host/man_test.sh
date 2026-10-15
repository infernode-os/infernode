#!/bin/sh
#
# man_test.sh — troff -man (/lib/tmac/tmac.an) and man -t:
#
#	every page of the manual (/man) set by troff -man and tr2pdf
#	without a word on the standard error, its words (man2txt's) in
#	the PDF's text, but for a handful (the sources' own slips, words
#	pdftotext joins over a hyphen at a line's end);
#	a page made for it, where each macro is checked by where its words
#	are: the head (name and section, both ends) and the folio; .SH at
#	the margin, its text 3.6 ems in; a .TP tag narrower than the indent
#	beside its paragraph, a wider one above it; .IP; .RS and .RE
#	nested; .TF's indent; an alternation of nine words, one with a
#	quote (Plan 9's macros set six, and compared the arguments between
#	quotes); .EX in constant width; two pages in one run, each its own
#	folios; man -t, troff's output for a page.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "man_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/troff.dis" ] && [ -f "$ROOT/dis/tr2pdf.dis" ] && [ -f "$ROOT/dis/man2txt.dis" ] ||
    { echo "man_test: SKIP (dis not built)"; exit 77; }
command -v pdftotext >/dev/null 2>&1 || { echo "man_test: SKIP (no pdftotext)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "man_test: SKIP (no python3)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/man.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/m"

# the manual, in eight emus at once
ls man/[0-9]/* | grep -v '/INDEX$' > "$tmp/list"
split -n l/8 "$tmp/list" "$tmp/part."
for p in "$tmp"/part.*; do
    for f in $(cat "$p"); do
        n=$(echo "$f" | tr / _)
        echo "troff -man /$f > $n.out >[2] $n.err; tr2pdf $n.out > $n.pdf >[2] $n.perr; man2txt /$f > $n.txt >[2] /dev/null"
    done > "$p.sh"
    with_timeout 600 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp/m'; run '#U*$p.sh'" </dev/null >/dev/null 2>&1 &
done
wait

python3 -I - "$tmp/m" "$(wc -l < "$tmp/list")" <<'PY' || fail=1
import sys, glob, re, os, subprocess, collections
d, n = sys.argv[1], int(sys.argv[2])
fail = 0
def check(ok, what, why=''):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what + ('' if ok else ': ' + str(why)[:400]))
    fail |= not ok
pdfs = glob.glob(d + '/*.pdf')
said = [(os.path.basename(f), open(f, errors='replace').read().strip()) for f in glob.glob(d + '/*.err') + glob.glob(d + '/*.perr')]
said = [s for s in said if s[1]]
empty = [p for p in pdfs if os.path.getsize(p) < 1000]
check(len(pdfs) == n and not said and not empty,
      'every page of the manual set without a word (%d pages)' % len(pdfs), (len(pdfs), said[:3], empty[:3]))
missing = []
total = 0
for txt in glob.glob(d + '/*.txt'):
    t = subprocess.run(['pdftotext', txt[:-4] + '.pdf', '-'], capture_output=True, text=True).stdout
    src = open(txt, errors='replace').read().replace('Inferno Manual', '')
    have = set(re.findall(r'[A-Za-z]{4,}', t + re.sub(r'-\n', '', t) + t.replace('\n', '')))
    joined = set(re.findall(r'[A-Za-z]+', t.replace('\n', ' ')))
    ok = set()
    for c in re.findall(r'[A-Za-z]+(?:-[A-Za-z]+)+', src):
        if c.replace('-', '') in joined:
            ok.update(c.split('-'))
    want = set(re.findall(r'[A-Za-z]{4,}', src))
    total += len(want)
    missing += [(os.path.basename(txt), w) for w in want if w not in have and w not in ok]
check(total > 30000 and len(missing) <= 15,
      "the manual's words in its PDFs (%d of %d not)" % (len(missing), total), missing[:10])
sys.exit(fail)
PY

# the macros, by where their words are set
cat > "$tmp/x.man" <<'EOF'
.TH XTEST 9 "Test heading"
.SH NAME
xtest \- the macros tried
.SH DESCRIPTION
Bodytext begins here.
.TP
.B -s
Shorttag paragraph.
.TP
.B -averyverylongtagindeed
Longtag paragraph.
.IP 1)
Ipara item.
.RS
Nestedonce text.
.RS
Nestedtwice text.
.RE
Backonce text.
.RE
Backbody text.
.TF longestflag
.TP
.B -x
Tfpara text.
.PD
.PP
.RB ( one | two ", " "three=" "\fIfour\fP, " "five=" "N, " "six=" "seven" ) eight;
.RB `` quoted ''.
.EX
example code
.EE
.SS Subheading
Subtext follows.
.TH SECOND 9
.SH NAME
second \- another page
EOF
with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd '#U*$tmp'; troff -man x.man > x.out >[2] x.err; tr2pdf x.out > x.pdf; man -t cat > cat.out" </dev/null >/dev/null 2>&1
pdftotext -bbox "$tmp/x.pdf" "$tmp/x.html" 2>/dev/null
python3 -I - "$tmp/x.html" "$tmp/x.err" "$tmp/x.out" <<'PY' || fail=1
import sys, re, html
bbox, err, out = sys.argv[1:4]
fail = 0
def check(ok, what, why=''):
    global fail
    print(('PASS: ' if ok else 'FAIL: ') + what + ('' if ok else ': ' + str(why)[:400]))
    fail |= not ok
pages = []
for m in re.finditer(r'<page width="[\d.]+" height="([\d.]+)">(.*?)</page>', open(bbox, encoding='utf-8').read(), re.S):
    pages.append([(float(a), float(b), html.unescape(w)) for a, b, w in
        re.findall(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="[\d.]+" yMax="[\d.]+">([^<]*)<', m.group(2))])
def at(w, p=0):
    for x in pages[p]:
        if x[2] == w:
            return x
    return None
check(len(pages) == 2 and not open(err).read().strip(), 'two pages, nothing said', (len(pages), open(err).read()))
p0 = pages[0]
heads = [x for x in p0 if x[2].startswith('XTEST(9)')]
fol = [x for x in p0 if x[2] == '1' and x[1] > 700]
check(len(heads) == 2 and abs(heads[0][1] - heads[1][1]) < 1 and at('(Test') and fol,
      'the head, name and section at both ends, the heading between; the folio', (heads, fol))
sh, body = at('NAME'), at('Bodytext')
indent = body[0] - sh[0]
check(abs(sh[0] - 72) < 1 and abs(indent - 3.6 * 9) < 1.5, '.SH at the margin, the text 3.6 ems in', (sh, body))
s, sp = at('-s'), at('Shorttag')
l, lp = at('-averyverylongtagindeed'), at('Longtag')
check(abs(s[1] - sp[1]) < 1 and sp[0] > s[0] and abs(s[0] - body[0]) < 1,
      'a narrow .TP tag beside its paragraph', (s, sp))
check(lp[1] > l[1] + 5 and abs(lp[0] - sp[0]) < 1, 'a wide .TP tag above its paragraph, at its indent', (l, lp))
i1, ip = at('1)'), at('Ipara')
check(abs(i1[1] - ip[1]) < 1 and abs(ip[0] - sp[0]) < 1, '.IP: its tag beside, its text at the indent', (i1, ip))
n1, n2, b1, bb = at('Nestedonce'), at('Nestedtwice'), at('Backonce'), at('Backbody')
check(n2[0] > n1[0] > bb[0] and abs(b1[0] - n1[0]) < 1 and abs(bb[0] - body[0]) < 1,
      '.RS and .RE nested, and back', (n1, n2, b1, bb))
x, tf = at('-x'), at('Tfpara')
check(abs(x[1] - tf[1]) < 1 and 30 < tf[0] - x[0] < 80, ".TF: the paragraphs indented by its word's width", (x, tf))
# alternated words are set together, apart only where the arguments
# had blanks
e = [w for w in p0 if w[2].endswith('eight;')]
line = ' '.join(w[2] for w in sorted((w for w in p0 if e and abs(w[1] - e[0][1]) < 1), key=lambda w: w[0]))
check(line.startswith('(one|two, three=four, five=N, six=seven)eight;'),
      'an alternation of nine words, every one set', line)
q = [w[2] for w in p0 if 'quoted' in w[2]]
check(q == ['‘‘quoted’’.'], 'an argument with a quote in an alternation set', q)
o = open(out, encoding='utf-8').read()
check(re.search(r'x font 5 CR', o) is not None, '.EX and .B in constant width (Libertinus Mono)')
check(at('SECOND(9)', 1) is not None and any(w[2] == '1' and w[1] > 700 for w in pages[1]),
      'a second page in one run, its own head and folio 1')
PY
if grep -q '^x T utf' "$tmp/cat.out" && grep -q '^cC' "$tmp/cat.out"; then
    echo "PASS: man -t: troff's output for a page"
else
    echo "FAIL: man -t: $(head -c 200 "$tmp/cat.out")"; fail=1
fi
exit $fail
