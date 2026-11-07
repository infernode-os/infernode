#!/bin/bash
#
# tests/host/camera_layers_test.sh
#
# wm/camera draws its feed's layers (#1095, layers(2)) as the name space
# stacks them, by pixel, over camsrv -t (no camera needed): camsrv
# serves an empty layer/, wm/camera under wm/wm, the screen captured
# (scap) after each change:
#
#   1. no layer: the test pattern alone
#   2. a magenta box layer (frame=*) bound: drawn (magenta pixels
#      beyond the pattern's own)
#   3. unmounted: back to the pattern alone
#   4. a layer keyed to a frame far ahead: not drawn yet
#   5. one keyed to frame 1: drawn (the camera numbers its frames, so a
#      record for frame N is drawn from N on)
#
# Needs the SDL emulator (SDL's dummy driver keeps it headless).
#
# Run from project root: ./tests/host/camera_layers_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in wm/camera.dis camsrv.dis lib/layers.dis scap.dis mntgen.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

W="$ROOT/tmp/camera_layers_test.$$"
rm -rf "$W"
mkdir -p "$W/box" "$W/keyed" "$W/early"
trap 'rm -rf "$W"' EXIT
E=/tmp/camera_layers_test.$$

echo 'frame=* box x0=20 y0=20 x1=140 y1=100 label=door colour=ff00ff' > "$W/box/door"
echo 'frame=100000000 box x0=20 y0=20 x1=140 y1=100 label=later colour=ff00ff' > "$W/keyed/later"
echo 'frame=1 box x0=20 y0=20 x1=140 y1=100 label=one colour=ff00ff' > "$W/early/one"

cat > "$W/run.sh" <<RUN
mount -ac {mntgen} /mnt
mount -A {camsrv -t} /mnt/video
ls -d /mnt/video/0/layer; echo LAYERDIR-\$status
wm/camera &
sleep 5
scap $E/1.img
bind -a $E/box /mnt/video/0/layer
sleep 2
scap $E/2.img
unmount $E/box /mnt/video/0/layer
sleep 2
scap $E/3.img
bind -a $E/keyed /mnt/video/0/layer
sleep 2
scap $E/4.img
unmount $E/keyed /mnt/video/0/layer
bind -a $E/early /mnt/video/0/layer
sleep 2
scap $E/5.img
echo LAYERS-DONE
echo halt > '#c/sysctl'
RUN
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
	-g1000x800 -r"$ROOT" wm/wm sh "$E/run.sh" > "$W/log" 2>&1 < /dev/null
if ! grep -q 'scap: wrote' "$W/log"; then
	if grep -q -i 'no display\|headless\|cannot.*draw\|winctl' "$W/log"; then
		echo "SKIP: no display in this emulator (a headless build)"
		exit 77
	fi
	echo "FAIL: no screen captured"; grep -v fsqid "$W/log" | tail -10; exit 1
fi
grep -q '^LAYERS-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -10; exit 1; }
fail=0
if grep -q '^LAYERDIR-$' "$W/log"; then echo "PASS: camsrv serves layer/"; else echo "FAIL: camsrv serves no layer/"; fail=1; fi

counts=$(python3 - "$ROOT/tools" "$W" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
for n in "12345":
    rgb = load("%s/%s.img" % (sys.argv[2], n)).rgb
    m = 0
    for p in range(0, len(rgb), 3):
        r, g, b = rgb[p], rgb[p+1], rgb[p+2]
        if r > 220 and b > 220 and g < 40:
            m += 1
    print(n, m)
PY
)
base=$(echo "$counts" | awk '$1 == 1 {print $2}')
for line in "2|a frame=* box layer bound: drawn|some" \
	"3|unmounted: gone|none" "4|a layer keyed to a frame far ahead: not drawn yet|none" \
	"5|a layer keyed to frame 1: drawn on the frames after it|some"; do
	IFS='|' read -r n what want <<<"$line"
	m=$(echo "$counts" | awk -v n="$n" '$1 == n {print $2}')
	d=$((m - base))
	ok=1
	case "$want" in
	none) [ "${d#-}" -lt 150 ] || ok=0 ;;
	some) [ "$d" -gt 400 ] || ok=0 ;;
	esac
	if [ $ok = 1 ]; then echo "PASS: $what (magenta $m, pattern alone $base)"; else echo "FAIL: $what (magenta $m, pattern alone $base)"; fail=1; fi
done
exit $fail
