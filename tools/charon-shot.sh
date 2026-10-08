#!/bin/sh
#
# charon-shot.sh — render a page with Charon headlessly and write a PNG.
#
#   usage: tools/charon-shot.sh [-o] [-d] <url-or-file> <out.png> [width[xheight]]
#
# -o renders with the old engine; -d prints the box tree.
#
# With just a width, the image is cropped to the page length; with
# widthxheight it is exactly that viewport.
#
# A local file is rendered via file://; its path must be inside the
# InferNode root (emu only sees $ROOT). The render uses Charon's
# -render mode (lay out once, dump the frame, exit), so no display or
# window manager is needed.
#
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAGS=""
while [ "${1#-}" != "$1" ]; do FLAGS="$FLAGS $1"; shift; done
SRC="$1"; OUT="$2"; W="${3:-1024}"
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "usage: $0 <url-or-file> <out.png> [width[xheight]]" >&2; exit 2; }
case "$(uname -s)" in
Darwin) EMU="$ROOT/emu/MacOSX/o.emu" ;;
*)      EMU="$ROOT/emu/Linux/o.emu" ;;
esac
[ -x "$EMU" ] || { echo "build the emulator first ($EMU)" >&2; exit 1; }
[ -f "$ROOT/dis/tests/charonshot.dis" ] || { echo "build tests first: (cd tests; mk install)" >&2; exit 1; }
case "$SRC" in
*://*) URL="$SRC" ;;
*)
	ABS="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
	case "$ABS" in
	"$ROOT"/*) URL="file://${ABS#$ROOT}" ;;
	*) echo "$SRC is not inside $ROOT" >&2; exit 1 ;;
	esac ;;
esac
IMG=".charonshot.$$.img"
rm -f "$ROOT/$IMG"
# charonshot halts emu when done; emu's halt SIGKILLs its whole process
# group, so give it its own (setsid) and collect its output from a file.
# The timeout is the backstop for a render that never finishes.
LOG="$ROOT/.charonshot.$$.log"
( setsid -w timeout "${CHARONSHOT_TIMEOUT:-60}" "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -r"$ROOT" \
	/dis/tests/charonshot.dis $FLAGS "$W" "/$IMG" "$URL" </dev/null >"$LOG" 2>&1 ) 2>/dev/null || true
grep -vE '^fs: fsqid|^PERF:|^Killed$' "$LOG" >&2 || true
rm -f "$LOG" "$ROOT/$IMG.txt"
[ -s "$ROOT/$IMG" ] || { echo "no image produced" >&2; exit 1; }
python3 "$ROOT/tools/p9img2png.py" "$ROOT/$IMG" "$OUT" >/dev/null
rm -f "$ROOT/$IMG"
echo "$OUT"
