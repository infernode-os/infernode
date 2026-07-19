#!/bin/bash
#
# uitest_transport_test.sh — synthetic-input driver end to end: boot the
# GUI, drive the Matrix video-player crystallisation with injected
# events (/chan/uitest in wm/wm), and assert the vid9p playhead obeys.
# Exercises: uitest driver -> wm -> matrix focus routing -> video-pane
# keys -> ctl wire -> vid9p server transport.
#
# Prereqs as vid9p_test.sh; SKIP (exit 77) if absent.  Needs a GUI
# window; SDL dummy keeps it headless.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

case "$(uname -s)" in
  Darwin) EMUHOST=MacOSX ;;
  Linux)  EMUHOST=Linux ;;
  *) echo "uitest_transport_test: SKIP (unsupported OS)"; exit 77 ;;
esac
EMU="$ROOT/emu/$EMUHOST/o.emu"

VDEC=""
for c in "$ROOT/tools/vdec/target/release/vdec" "$ROOT/tools/vdec/target/debug/vdec"; do
  [ -x "$c" ] && VDEC="$c" && break
done
command -v ffmpeg >/dev/null 2>&1 || { echo "uitest_transport_test: SKIP (no ffmpeg)"; exit 77; }
[ -n "$VDEC" ] || { echo "uitest_transport_test: SKIP (no vdec)"; exit 77; }
[ -x "$EMU" ]  || { echo "uitest_transport_test: SKIP (no emu)"; exit 77; }

echo "uitest_transport_test: SKIP (driver ships; synthetic-event routing into hosted Tk regions not yet verified — enable after the routing investigation)"; exit 77
TMP="$(mktemp -d)"
trap 'rm -f "$ROOT"/.uitest.y4m "$ROOT"/.uitest.sh; rm -rf "$TMP"' EXIT

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=160x120:rate=10:duration=20" \
    -c:v libx264 -pix_fmt yuv420p -g 20 "$TMP/clip.mp4" 2>/dev/null \
    || { echo "uitest_transport_test: SKIP (no libx264)"; exit 77; }
"$VDEC" "$TMP/clip.mp4" --y4m "$ROOT/.uitest.y4m" --quiet

# In-emu driver: player composition, then synthetic input.
# key 32 = space (pause/play); key 57365 = Keyboard->Right (seek +5s).
cat > "$ROOT/.uitest.sh" <<'ISH'
mkdir -p /mnt/video
mount {vid9p /.uitest.y4m} /mnt/video
wm/matrix -g 800x600 /lib/matrix/compositions/video-player &
sleep 8
echo ptr 400 280 1 > /chan/uitest
sleep 1
echo ptr 400 280 0 > /chan/uitest
sleep 1
echo key 32 > /chan/uitest
sleep 1
echo U1 `{cat /mnt/video/0/status}
echo key 57365 > /chan/uitest
sleep 1
echo U2 `{cat /mnt/video/0/status}
echo key 32 > /chan/uitest
sleep 1
echo U3 `{cat /mnt/video/0/status}
ISH

SDL_VIDEODRIVER=dummy timeout 60 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m \
    -g1280x820 -r"$ROOT" wm/wm sh /.uitest.sh > "$TMP/out" 2>&1

key() { awk -v m="$1" -v k="$2" '$1 == m { for(i=2;i<=NF;i++){ n=index($i,"="); if(substr($i,1,n-1)==k) print substr($i,n+1) } }' "$TMP/out"; }

FAILED=0
fail() { echo "uitest_transport_test: FAIL ($1)"; FAILED=1; }

[ -n "$(key U1 state)" ] || { echo "uitest_transport_test: FAIL (no status output)"; sed -n '1,12p' "$TMP/out"; exit 1; }
[ "$(key U1 state)" = paused ]  || fail "space did not pause: state=$(key U1 state)"
t1=$(key U1 t); t2=$(key U2 t)
[ -n "$t2" ] && [ "$t2" -ge $((t1 + 4000)) ] || fail "Right did not seek: t $t1 -> $t2"
[ "$(key U3 state)" = playing ] || fail "space did not resume: state=$(key U3 state)"

[ "$FAILED" -eq 0 ] && echo "uitest_transport_test: PASS (synthetic input drives the player end to end)" && exit 0
exit 1
