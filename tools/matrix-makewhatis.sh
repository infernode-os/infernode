#!/bin/sh
#
# matrix-makewhatis.sh — regenerate lib/matrix/index from the NAME
# lines of lib/matrix/man/*, in whatis(1) shape:
#
#   name (type) - synopsis
#
# The index is the agent-facing scan surface: one line per module,
# read in a single gulp through /mnt/matrix/library/index.  The man
# page it points at carries the contract (READS/WRITES).  Run after
# adding or renaming a module man page; the result is checked in,
# like the dis/ tree, so a fresh clone serves a complete library.
#
# Usage: tools/matrix-makewhatis.sh [ROOT]

set -eu

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MANDIR="$ROOT/lib/matrix/man"
INDEX="$ROOT/lib/matrix/index"

[ -d "$MANDIR" ] || { echo "matrix-makewhatis: no $MANDIR" >&2; exit 1; }

tmp="$INDEX.tmp"
: > "$tmp"

for page in "$MANDIR"/*; do
	[ -f "$page" ] || continue
	# The synopsis is the first non-blank line after the NAME
	# heading, with leading whitespace stripped.
	line=$(awk '
		$0 == "NAME" { grab = 1; next }
		grab && NF > 0 { sub(/^[ \t]+/, ""); print; exit }
	' "$page")
	if [ -z "$line" ]; then
		echo "matrix-makewhatis: $page has no NAME line" >&2
		rm -f "$tmp"
		exit 1
	fi
	printf '%s\n' "$line" >> "$tmp"
done

sort -o "$tmp" "$tmp"
mv "$tmp" "$INDEX"
echo "wrote $INDEX ($(wc -l < "$INDEX" | tr -d ' ') entries)"
