#!/bin/bash
#
# tests/host/layerfs_test.sh
#
# layerfs(4) (#1095): a directory where any file written is a layer.
# Union-mounted with create, through the shell and read(1), one read a
# check:
#
#   - a file written once: its records, at open, in one read
#   - appended to (>>): both; rewritten (>): only the new, and its
#     version changes (how layers(2) knows to read it again)
#   - of a stream, only what is due: the newest frame's records and the
#     frame=* ones, not the frames before
#   - a reader waits for what is written after it opened, and gets it
#   - a line that is no record is not kept
#   - a file removed is gone, and its waiting reader ends
#   - over a feed's layer/ (vid9p), a file written there is listed among
#     its layers, and vidplay9p draws it, by pixel (with the SDL
#     emulator; skipped with a headless one)
#
# Run from project root: ./tests/host/layerfs_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in layerfs.dis lib/layers.dis read.dis vid9p.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done

W="$ROOT/tmp/layerfs_test.$$"
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
E=/tmp/layerfs_test.$$

cat > "$W/run.sh" <<'RUN'
load std
mkdir -p /tmp/L
mount -ac {layerfs} /tmp/L
echo 'frame=* box x0=1 y0=1 x1=9 y1=9 label=door' > /tmp/L/roi
echo '-- once'; read 8192 < /tmp/L/roi
echo 'frame=* point x=4 y=5' >> /tmp/L/roi
echo '-- appended'; read 8192 < /tmp/L/roi
echo '-- vers before'; ls -q /tmp/L/roi
echo 'frame=* box x0=2 y0=2 x1=8 y1=8 label=gate' > /tmp/L/roi
echo '-- rewritten'; read 8192 < /tmp/L/roi
echo '-- vers after'; ls -q /tmp/L/roi
{
	echo 'frame=* text x=1 y=1 label=always'
	echo 'frame=1 box x0=1 y0=1 x1=2 y1=2 label=one'
	echo 'frame=2 box x0=1 y0=1 x1=3 y1=3 label=two'
	echo 'hello, not a record'
	echo 'frame=2 box x0=1 y0=1 x1=4 y1=4 label=two-b'
} > /tmp/L/people
echo '-- stream'; read 8192 < /tmp/L/people
{ sleep 2; echo 'frame=3 text x=1 y=1 label=three' >> /tmp/L/people } &
echo '-- waits'; { read 8192; echo '-- then'; read 8192 } < /tmp/L/people
{ sleep 2; rm /tmp/L/people } &
echo '-- removed'; { read 8192; read 8192; echo READ-$status } < /tmp/L/people
echo '-- ls'; ls /tmp/L
echo LAYERFS-DONE
echo halt > '#c/sysctl'
RUN
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" > "$W/log" 2>&1 < /dev/null
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
part() { sed -n "/^-- $1\$/,/^-- /p" "$W/log" | grep -v '^-- '; }
grep -q '^LAYERFS-DONE' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -15; exit 1; }

[ "$(part once)" = "frame=* box x0=1 y0=1 x1=9 y1=9 label=door" ] && ok "a file written once: its records at open" || bad "once: $(part once)"
[ "$(part appended | tr '\n' '|')" = "frame=* box x0=1 y0=1 x1=9 y1=9 label=door|frame=* point x=4 y=5|" ] && ok "appended to: both" || bad "appended: $(part appended | tr '\n' '|')"
[ "$(part rewritten)" = "frame=* box x0=2 y0=2 x1=8 y1=8 label=gate" ] && ok "rewritten: only the new" || bad "rewritten: $(part rewritten | tr '\n' '|')"
vb=$(part 'vers before' | awk '{print $2}'); va=$(part 'vers after' | awk '{print $2}')
[ -n "$vb" ] && [ "$vb" != "$va" ] && ok "rewritten: its version changes ($vb -> $va)" || bad "version: '$vb' '$va'"
[ "$(part stream | tr '\n' '|')" = "frame=* text x=1 y=1 label=always|frame=2 box x0=1 y0=1 x1=3 y1=3 label=two|frame=2 box x0=1 y0=1 x1=4 y1=4 label=two-b|" ] && ok "a stream: the newest frame's records and frame=*, not the frames before" || bad "stream: $(part stream | tr '\n' '|')"
part stream | grep -q hello && bad "a line that is no record was kept" || ok "a line that is no record is not kept"
[ "$(part then)" = "frame=3 text x=1 y=1 label=three" ] && ok "a reader waits for what is written after its open, and gets it" || bad "then: $(part then | tr '\n' '|')"
part removed | grep -q '^READ-' && ok "removed: its waiting reader ends" || bad "removed: $(part removed | tr '\n' '|')"
part ls | grep -q people && bad "removed: still listed: $(part ls | tr '\n' ' ')" || ok "removed: gone from the directory"

# over a feed's layer/, drawn: vidplay9p under wm/wm, by pixel
if [ -f "$ROOT/dis/mpeg/vidplay9p.dis" ] && [ -f "$ROOT/dis/scap.dis" ] && command -v python3 >/dev/null 2>&1; then
	python3 - "$W/grey.y4m" <<'PY'
import sys
w, h = 160, 120
with open(sys.argv[1], "wb") as f:
    f.write(b"YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n" % (w, h))
    for i in range(300):
        f.write(b"FRAME\n" + bytes([128]) * (w*h) + bytes([128]) * (w*h//2))
PY
	cat > "$W/view.sh" <<VIEW
mkdir -p /mnt/video
mount {vid9p $E/grey.y4m} /mnt/video
mount -ac {layerfs} /mnt/video/0/layer
mpeg/vidplay9p /mnt/video/0 &
sleep 3
scap $E/v1.img
echo 'frame=* box x0=20 y0=20 x1=140 y1=100 label=door colour=ff0000' > /mnt/video/0/layer/roi
sleep 2
echo '-- listed'; ls /mnt/video/0/layer
scap $E/v2.img
rm /mnt/video/0/layer/roi
sleep 2
scap $E/v3.img
echo VIEW-DONE
echo halt > '#c/sysctl'
VIEW
	SDL_VIDEODRIVER=dummy with_timeout 90 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
		-g1024x768 -r"$ROOT" wm/wm sh "$E/view.sh" > "$W/vlog" 2>&1 < /dev/null
	if grep -q 'scap: wrote' "$W/vlog" && grep -q '^VIEW-DONE' "$W/vlog"; then
		sed -n '/^-- listed$/,/^scap\|^VIEW/p' "$W/vlog" | grep -q 'layer/roi' && ok "over a feed's layer/: the file is one of its layers" || bad "not listed: $(grep -A3 '^-- listed' "$W/vlog" | tr '\n' ' ')"
		counts=$(python3 - "$ROOT/tools" "$W" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from p9img2png import load
for n in "123":
    rgb = load("%s/v%s.img" % (sys.argv[2], n)).rgb
    print(sum(1 for p in range(0, len(rgb), 3) if rgb[p] > 200 and rgb[p+1] < 60 and rgb[p+2] < 60))
PY
)
		set -- $counts
		[ "$1" -eq 0 ] && [ "$2" -gt 100 ] && [ "$3" -eq 0 ] && ok "written into the feed's layer/: drawn, and removed: gone (red $1 $2 $3)" || bad "drawn: red $1 $2 $3"
	else
		echo "SKIP: the drawing check (no display, or the session did not finish)"
	fi
fi
exit $fail
