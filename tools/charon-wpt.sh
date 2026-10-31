#!/bin/sh
#
# charon-wpt.sh — run Charon's render conformance fixtures and score them.
#
#   usage: tools/charon-wpt.sh [outdir] [fixture.html ...]
#
# Every fixture in tests/charon/wpt/ is built so that a correct rendering
# shows a solid green area and no pure red; red is what shows through
# when the feature under test is not implemented.  Scoring is by pixel
# count, so no reference images are needed.  PNGs are left in outdir
# (default: a temp dir) for eyeballing failures.
#
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$(mktemp -d)}"
[ $# -gt 0 ] && shift
mkdir -p "$OUT"
if [ $# -eq 0 ]; then set -- "$ROOT"/tests/charon/wpt/*.html; fi
pass=0; fail=0; failed=""
for f in "$@"; do
	name=$(basename "$f" .html)
	png="$OUT/$name.png"
	rm -f "$png"
	"$ROOT/tools/charon-shot.sh" "$f" "$png" 400x300 >/dev/null 2>"$OUT/$name.log"
	if [ -s "$png" ]; then
		verdict=$(python3 "$ROOT/tools/charon-wpt-score.py" "$png")
	else
		verdict="FAIL no image"
	fi
	printf '%-22s %s\n' "$name" "$verdict"
	case "$verdict" in
	PASS*) pass=$((pass+1)) ;;
	*) fail=$((fail+1)); failed="$failed $name" ;;
	esac
done
echo "passed $pass/$((pass+fail))  (images in $OUT)"
[ $fail -eq 0 ]
