#!/bin/sh
#
# refer_test.sh — refer(1): citations by key, from refer's databases and
# BibTeX's, plain (Neatrefer's) and in the Chicago style.
#
#	without a style, the output is Neatrefer's: tests/refer/ms.out was
#	made by Neatrefer from ms.tr and db.ref;
#	with -S chicago, tests/refer/chicago.tr cites the works of
#	works.bib (examples after The Chicago Manual of Style, 18th
#	edition) as tests/refer/chicago.out gives them: full notes, then
#	short; et al. past three authors in a note, past six in the
#	bibliography; translated, edited, chapter, article (DOI), thesis
#	and classical works; inclusive page ranges (101–8, 321–28); a
#	title ending in ? keeping its comma; a chapter citing in full
#	again; the bibliography sorted, accents aside.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "refer_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/refer.dis" ] || { echo "refer_test: SKIP (dis not built)"; exit 77; }

fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/refer.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c \
    "cd /tests/refer; refer -p db.ref -ocite -sa < ms.tr > '#U*$tmp/ms.out'; refer -p works.bib -S chicago < chicago.tr > '#U*$tmp/chicago.out'" \
    </dev/null >/dev/null 2>&1

for t in ms chicago; do
    if cmp -s "$tmp/$t.out" "tests/refer/$t.out"; then
        echo "PASS: $t"
    else
        echo "FAIL: $t:"
        diff "tests/refer/$t.out" "$tmp/$t.out" | head -20 | sed 's/^/    /'
        fail=1
    fi
done
exit $fail
