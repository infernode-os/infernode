#!/bin/sh
#
# wm_dir_test.sh — wm/dir (appl/wm/dir.b), Inferno's file browser, under
# wm/wm, driven by the pointer (tests/dir/drive.sh): its icons are drawn
# (icon(2)'s glyphs, on the theme's background), a folder double-clicked
# opens in the same window and .. goes back, a file double-clicked with
# no plumber opens in wm/edit, and with a plumber is plumbed, its full
# name and the folder as the working directory.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/dir.dis dis/wm/edit.dis dis/wm/wm.dis dis/lib/icon.dis dis/plumber.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/wm_dir_test.$$
D="$ROOT/$T"
mkdir -p "$D/tree/sub"
LOG=$(mktemp)
trap 'rm -f "$LOG"; rm -rf "$D"' EXIT
printf 'readme\n' > "$D/tree/README"
printf '# notes\n' > "$D/tree/notes.md"
printf 'implement Inner;\n' > "$D/tree/sub/inner.b"
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/dir/drive.sh /$T" </dev/null >"$LOG" 2>&1 || true

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }
windows() { sed -n "s/^R $1 *//p" "$LOG" | head -1; }
nwin() { set -- $(windows "$1"); echo $(($# / 5)); }

if ! grep -q '^R done' "$LOG"; then
	bad "the drive did not finish"
	cat "$LOG"
	exit 1
fi

# glyphs STEP: how many icons the top row of STEP's screenshot shows,
# as runs of columns, across the glyphs' band (y 32 to 60), with pixels
# unlike the background
glyphs() {
	python3 -I - "$D/$1.img" <<'PY'
import sys
sys.path.insert(0, 'tools')
import p9img2png
im = p9img2png.load(sys.argv[1])
bg = im.px(20, 80)
cols = [any(im.px(x, y) != bg for y in range(32, 61)) for x in range(8, 460)]
runs, prev, gap = 0, False, 99
for c in cols:
    if c and not prev and gap > 6:
        runs += 1
    gap = 0 if c else gap + 1
    prev = c
print(runs)
PY
}

set -- $(windows start) 0 0 0 0 0
if [ $(($4 - $2)) -ge 300 ] && [ $(($5 - $3)) -ge 200 ]; then
	ok "opens at $(($4 - $2))x$(($5 - $3))"
else
	bad "opens at $(($4 - $2))x$(($5 - $3))"
fi

[ "$(glyphs start)" = 4 ] && ok "four icons: .., README, notes.md, sub" \
	|| bad "$(glyphs start) icons, not 4"

if [ "$(nwin walked)" = 1 ] && [ "$(glyphs walked)" = 2 ]; then
	ok "sub opened in the same window: .. and inner.b"
else
	bad "sub: $(nwin walked) windows, $(glyphs walked) icons"
fi

if [ "$(nwin back)" = 1 ] && [ "$(glyphs back)" = 4 ]; then
	ok ".. went back up"
else
	bad "..: $(nwin back) windows, $(glyphs back) icons"
fi

[ "$(nwin edit)" = 2 ] && ok "README with no plumber: a wm/edit window" \
	|| bad "README with no plumber: $(nwin edit) windows (windows: $(windows edit))"

if grep -q "/$T/tree/notes.md" "$D/plumbed" 2>/dev/null; then
	ok "notes.md with a plumber: plumbed by its full name"
else
	bad "notes.md was not plumbed (got: $(tr -d '\0' < "$D/plumbed" 2>/dev/null | head -c 200))"
fi
if grep -q "/$T/tree/" "$D/plumbed" 2>/dev/null && tr '\0' '\n' < "$D/plumbed" | grep -qx "/$T/tree/"; then
	ok "its working directory the folder"
else
	bad "the working directory was not the folder (got: $(tr '\0\n' '||' < "$D/plumbed" 2>/dev/null | head -c 200))"
fi

exit $failed
