#!/bin/sh
#
# icons_test.sh — the tree's icons are icon(2)'s glyphs and nothing
# else, and nothing names one that is not there:
#
#  - icons/ holds icons/ui (Tabler's SVGs, LIST, LICENSE), in icons/tk
#    only the cursors programs ask Tk for, and the pictures that are
#    artwork rather than icons: wm/coffee's cups and backdrop and the
#    picture draw-example(2) draws, kept as they were;
#  - icons/ui/LIST and the SVGs beside it are the same set;
#  - every glyph a program names (icon->paint, tkimage, a (tkname,
#    glyph, size) set, wm/dir's kinds, dialog(2)'s icons) is in it;
#  - no source names a file under /icons that is not in the tree, and no
#    Tk -bitmap, -file or -maskfile names one missing from /icons/tk (a
#    missing one fails the widget naming it, and the program with it).
#
set -eu
ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }

# icons/ holds only icons/ui and icons/tk/cursor.*
art='^icons/(coffee[0-5]\.(bit|mask)|bigdelight\.bit|delight\.bit)$'
other=$(git ls-files icons | grep -v '^icons/ui/' | grep -v '^icons/tk/cursor\.' | grep -Ev "$art" || true)
[ -z "$other" ] && ok "icons/ holds icon(2)'s glyphs, Tk's cursors and coffee's and draw-example's pictures only" \
	|| bad "old icons in the tree: $(echo $other)"

listed=$(sed 's/#.*//' icons/ui/LIST | tr -s ' \t\n' '\n' | grep . | sort)
svgs=$(git ls-files 'icons/ui/*.svg' | sed 's|icons/ui/||; s|\.svg$||' | sort)
[ "$listed" = "$svgs" ] && ok "LIST names exactly the $(echo "$svgs" | wc -l | tr -d ' ') SVGs in icons/ui" \
	|| bad "LIST and icons/ui differ: $(printf '%s\n' "$listed" "$svgs" | sort | uniq -u | tr '\n' ' ')"

# the glyphs programs name
named=$(git grep -h -o -E \
	-e '(^|[{,[:space:]])\("[A-Za-z_]+", *"[a-z0-9-]+", *[0-9]+\)' \
	-e 'paint\("[a-z0-9-]+"' \
	-e 'tkimage\([^,]+, *"[^"]+", *"[a-z0-9-]+"' \
	-e 'Ft\("[a-z0-9-]+"' \
	-e 'glyph = "[a-z0-9-]+"' \
	-- 'appl/*.b' 2>/dev/null |
	sed -E 's/.*"([a-z0-9-]+)"(, *[0-9]+\))?$/\1/; s/.*"([a-z0-9-]+)"$/\1/' | sort -u)
missing=""
for g in $named; do
	printf '%s\n' "$svgs" | grep -qx "$g" || missing="$missing $g"
done
[ -z "$missing" ] && ok "every glyph a program names is there ($(echo $named | wc -w | tr -d ' '))" \
	|| bad "glyphs named and not in icons/ui:$missing"

# paths under /icons in source and data
gone=""
for p in $(git grep -h -o -I -E '/icons/[a-z0-9_./-]+\.(bit|mask|svg|9)' -- appl lib module services man os/init 2>/dev/null | sort -u); do
	[ -f ".$p" ] || gone="$gone $p"
done
[ -z "$gone" ] && ok "every /icons path named in the tree is there" \
	|| bad "named and not there:$gone"

# Tk bitmap files: -bitmap, -file, -maskfile with a literal name, which Tk
# looks for in /icons/tk unless it is a path
gone=""
for f in $(git grep -h -o -E -e '-(bitmap|file|maskfile) [A-Za-z0-9_.]+(\.bit|\.mask|\.[a-z]+)' -- 'appl/*.b' 2>/dev/null |
	sed -E 's/^-[a-z]+ //' | sort -u); do
	[ -f "icons/tk/$f" ] || gone="$gone $f"
done
[ -z "$gone" ] && ok "every Tk bitmap a program names is in /icons/tk" \
	|| bad "Tk bitmaps named and not there:$gone"

exit $failed
