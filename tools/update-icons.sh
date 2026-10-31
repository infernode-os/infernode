#!/bin/sh
#
# update-icons.sh — fetch the glyphs icons/ui/LIST names from the pinned
# Tabler Icons release into icons/ui/NAME.svg, as Tabler draws them, and
# Tabler's licence beside them.  Run from anywhere; needs curl.  A name
# Tabler has not got is reported and the rest are still fetched.
#
# Each glyph is about 500 bytes; only those listed are kept in the tree.
#
set -eu
TABLER=3.19.0
BASE="https://cdn.jsdelivr.net/npm/@tabler/icons@$TABLER"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/icons/ui"

failed=0
for n in $(sed 's/#.*//' "$D/LIST"); do
	if curl -fsS "$BASE/icons/outline/$n.svg" -o "$D/$n.svg.new"; then
		mv "$D/$n.svg.new" "$D/$n.svg"
	else
		rm -f "$D/$n.svg.new"
		echo "update-icons: Tabler $TABLER has no outline glyph '$n'" >&2
		failed=1
	fi
done
curl -fsS "$BASE/LICENSE" -o "$D/LICENSE"
# glyphs no longer listed
for f in "$D"/*.svg; do
	n=$(basename "$f" .svg)
	sed 's/#.*//' "$D/LIST" | grep -qx "$n" || { echo "update-icons: removing $n.svg (not in LIST)"; rm -f "$f"; }
done
exit $failed
