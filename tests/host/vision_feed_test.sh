#!/bin/bash
#
# tests/host/vision_feed_test.sh
#
# vision(4) following a feed (src), through vid9p(1):
#
#   - a clip that has ended (5 frames, the middle one grey): every frame
#     looked at in order, each read one frame's records keyed frame= pts=,
#     the grey frame its key alone, the session ended with the clip
#   - a live source faster than the detector (tests/host/vision/live.py,
#     20 frames a second): the session joins at the newest frame, takes
#     the newest each time it is ready, counts the rest as skipped, never
#     holds the feed back, and ends when the source does
#   - src none back to idle; a feed that is not one refused
#
# Needs a model directory and a picture of a dog (as vision_test.sh) and
# a Python with numpy and Pillow (VISION_PYTHON, default python3) to make
# the clip. Skips if any is missing.
#
# Run from project root: ./tests/host/vision_feed_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

PY="${VISION_PYTHON:-python3}"
for v in VISION_MODEL VISION_PICTURE; do
	[ -n "${!v:-}" ] && [ -e "${!v}" ] || { echo "SKIP: $v not set to something that exists"; exit 77; }
done
"$PY" -c 'import numpy, PIL' 2>/dev/null || { echo "SKIP: $PY lacks numpy or Pillow"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
for f in visionfs.dis vid9p.dis; do
	[ -f "$ROOT/dis/$f" ] || { echo "SKIP: dis/$f not built"; exit 77; }
done

W="$ROOT/tmp/vision_feed_test.$$"
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
"$PY" -I "$ROOT/tests/host/vision/mkclip.py" "$VISION_PICTURE" "$W/clip.y4m" 5 || { echo "FAIL: mkclip"; exit 1; }
PYABS="$(command -v "$PY")"
M=/tmp/h$VISION_MODEL
E=/tmp/h$W
cat > "$W/run.sh" <<RUN
load std
mkdir -p /mnt/video /mnt/live
mount {vid9p $E/clip.y4m} /mnt/video
mount {vid9p -c $PYABS $ROOT/tests/host/vision/live.py $W/clip.y4m} /mnt/live
visionfs -S load m $M
{
	id=\`{read}
	{
		echo src /mnt/video/0 > /mnt/vision/\$id/ctl
		echo '-- clip'
		cat
	} < /mnt/vision/\$id/detections
	echo '-- clip status'; cat /mnt/vision/\$id/status /mnt/vision/\$id/stats
	echo src none > /mnt/vision/\$id/ctl
	echo '-- idle'; cat /mnt/vision/\$id/status
	echo src /nowhere > /mnt/vision/\$id/ctl
	{
		echo src /mnt/live/0 > /mnt/vision/\$id/ctl
		echo '-- live'
		cat
	} < /mnt/vision/\$id/detections
	echo '-- live status'; cat /mnt/vision/\$id/status /mnt/vision/\$id/stats
} < /mnt/vision/clone
echo '-- END'
echo halt > '#c/sysctl'
RUN
with_timeout 300 "$EMU" -c1 -r"$ROOT" sh -c "mkdir -p /tmp/h; bind '#U*' /tmp/h; sh $E/run.sh" > "$W/log" 2>&1 < /dev/null

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
part() { sed -n "/^-- $1\$/,/^-- /p" "$W/log" | grep -v '^-- '; }
grep -q '^-- END' "$W/log" || { echo "FAIL: the session did not finish"; grep -v fsqid "$W/log" | tail -20; exit 1; }

frames=$(part clip | cut -d' ' -f1 | uniq | tr '\n' ' ')
[ "$frames" = "frame=0 frame=1 frame=2 frame=3 frame=4 " ] && ok "the clip, every frame in order" || bad "the clip's frames: $frames"
part clip | grep -q '^frame=2 pts=200$' && ok "the grey frame is its key alone" || bad "frame 2: $(part clip | grep '^frame=2')"
part clip | grep -q '^frame=3 pts=300 class=dog score=0\.[89][0-9] ' && ok "a frame's dog, keyed frame= pts=" || bad "frame 3: $(part clip | grep '^frame=3' | head -1)"
part 'clip status' | grep -q '^state=ended model=m src=/mnt/video/0$' && ok "the session ends with the clip" || bad "clip status: $(part 'clip status' | head -1)"
part 'clip status' | grep -q '^in=5 inferred=5 skipped=0 ' && ok "a clip that has ended is looked at whole" || bad "clip stats: $(part 'clip status' | tail -1)"
part idle | grep -q '^state=idle model=m$' && ok "src none: idle" || bad "after src none: $(part idle)"
grep -q 'write error: src: /nowhere/fmt' "$W/log" && ok "a feed that is not one is refused" || bad "src /nowhere not refused"
first=$(part live | head -1 | cut -d' ' -f1 | sed 's/frame=//')
nlive=$(part live | cut -d' ' -f1 | uniq | wc -l)
mono=$(part live | cut -d' ' -f1 | uniq | sed 's/frame=//' | awk 'NR>1 && $1<=p {bad=1} {p=$1} END {print bad+0}')
[ -n "$first" ] && [ "$first" -gt 0 ] && ok "live: joins at the newest frame ($first)" || bad "live: first frame '$first'"
[ "$mono" = 0 ] && [ "$nlive" -ge 5 ] && ok "live: $nlive frames, in order" || bad "live: $nlive frames, in order: $mono"
st=$(part 'live status' | tail -1)
sk=$(echo "$st" | sed -n 's/.*skipped=\([0-9]*\).*/\1/p')
inf=$(echo "$st" | sed -n 's/.*inferred=\([0-9]*\).*/\1/p')
[ -n "$sk" ] && [ "$sk" -gt 0 ] && [ "$inf" = "$nlive" ] && ok "live: the frames it was not ready for skipped ($st)" || bad "live stats: $st"
part 'live status' | grep -q '^state=ended ' && ok "live: ended with the source" || bad "live status: $(part 'live status' | head -1)"
exit $fail
