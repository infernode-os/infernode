#!/bin/bash
#
# tests/host/layers_view_test.sh
#
# Matrix's video-overlay draws its feed's layers (#1095) as the name space
# stacks them, by pixel: wm/matrix on the video-overlay composition over a
# grey vid9p clip, the screen captured (scap) after each change:
#
#   1. no layers: nothing red or green
#   2. a layer of a red box bound (bind -a): red, and no green
#   3. a layer of a green line bound above it: both
#   4. the red layer unmounted: green alone
#
# so a bind or an unmount made while the pane runs is drawn within a
# second, with no setting anywhere. Needs the SDL emulator (SDL's dummy
# driver keeps it headless); skips with a headless build.
#
# Run from project root: ./tests/host/layers_view_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in matrix/video-overlay.dis vid9p.dis lib/layers.dis scap.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

W="$ROOT/tmp/layers_view_test.$$"
rm -rf "$W"
mkdir -p "$W/red" "$W/green"
trap 'rm -rf "$W"' EXIT
E=/tmp/layers_view_test.$$

python3 - "$W/grey.y4m" <<'PY'
import sys
w, h = 160, 120
with open(sys.argv[1], "wb") as f:
    f.write(b"YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n" % (w, h))
    for i in range(40):
        f.write(b"FRAME\n" + bytes([128]) * (w*h) + bytes([128]) * (w*h//2))
PY
echo 'frame=* box x0=20 y0=20 x1=140 y1=100 label=door colour=ff0000' > "$W/red/door"
echo 'frame=* line x0=10 y0=60 x1=150 y1=60 colour=00ff00' > "$W/green/horizon"

cat > "$W/run.sh" <<RUN
mkdir -p /mnt/video
mount {vid9p $E/grey.y4m} /mnt/video
wm/matrix -g 800x600 /lib/matrix/compositions/video-overlay &
sleep 5
scap $E/1.img
bind -a $E/red /mnt/video/0/layer
sleep 2
scap $E/2.img
bind -a $E/green /mnt/video/0/layer
sleep 2
scap $E/3.img
unmount $E/red /mnt/video/0/layer
sleep 2
scap $E/4.img
echo LAYERS-DONE
echo halt > '#c/sysctl'
RUN
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
	-g1024x768 -r"$ROOT" wm/wm sh "$E/run.sh" > "$W/log" 2>&1 < /dev/null
if ! grep -q 'scap: wrote' "$W/log"; then
	if grep -q -i 'no display\|headless\|cannot.*draw\|winctl' "$W/log"; then
		echo "SKIP: no display in this emulator (a headless build)"
		exit 77
	fi
	echo "FAIL: no screen captured"; grep -v fsqid "$W/log" | tail -10; exit 1
fi
grep -q '^LAYERS-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -10; exit 1; }

counts=$(python3 - "$ROOT/tools" "$W" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
for n in "1234":
    im = load("%s/%s.img" % (sys.argv[2], n))
    rgb = im.rgb
    red = green = 0
    for p in range(0, len(rgb), 3):
        r, g, b = rgb[p], rgb[p+1], rgb[p+2]
        if r > 200 and g < 60 and b < 60:
            red += 1
        elif g > 200 and r < 60 and b < 60:
            green += 1
    print(n, red, green)
PY
)
fail=0
for line in "1|no layers: nothing drawn|none" "2|a red box layer bound: drawn|red" \
	"3|a green line layer bound above: both drawn|both" "4|the red layer unmounted: green alone|green"; do
	IFS='|' read -r n what want <<<"$line"
	r=$(echo "$counts" | awk -v n="$n" '$1 == n {print $2}')
	g=$(echo "$counts" | awk -v n="$n" '$1 == n {print $3}')
	ok=1
	case "$want" in
	none)  [ "$r" -eq 0 ] && [ "$g" -eq 0 ] || ok=0 ;;
	red)   [ "$r" -gt 100 ] && [ "$g" -eq 0 ] || ok=0 ;;
	both)  [ "$r" -gt 100 ] && [ "$g" -gt 50 ] || ok=0 ;;
	green) [ "$r" -eq 0 ] && [ "$g" -gt 50 ] || ok=0 ;;
	esac
	if [ $ok = 1 ]; then echo "PASS: $what (red $r, green $g)"; else echo "FAIL: $what (red $r, green $g)"; fail=1; fi
done
exit $fail
