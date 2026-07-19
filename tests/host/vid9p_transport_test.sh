#!/bin/bash
#
# vid9p_transport_test.sh - the server-side transport and the live
# retention window (INFR-266).
#
#   static: playhead paces at the stream fps; pause freezes it; absolute
#           and relative seek land exactly; stop rewinds.
#   live:   -w bounds retention (first= advances) and a read below the
#           window errors "frame expired".
#
# Prereqs as vid9p_test.sh: ffmpeg (libx264), a vdec binary, emu, and a
# built dis/vid9p.dis.  SKIP (exit 77) if absent, per INFR-34.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

case "$(uname -s)" in
  Darwin) EMUHOST=MacOSX ;;
  Linux)  EMUHOST=Linux ;;
  *) echo "vid9p_transport_test: SKIP (unsupported OS)"; exit 77 ;;
esac
EMU="$ROOT/emu/$EMUHOST/o.emu"

VDEC=""
for c in "$ROOT/tools/vdec/target/release/vdec" "$ROOT/tools/vdec/target/debug/vdec"; do
  [ -x "$c" ] && VDEC="$c" && break
done

command -v ffmpeg >/dev/null 2>&1 || { echo "vid9p_transport_test: SKIP (no ffmpeg)"; exit 77; }
[ -n "$VDEC" ]        || { echo "vid9p_transport_test: SKIP (no vdec binary; build tools/vdec)"; exit 77; }
[ -x "$EMU" ]         || { echo "vid9p_transport_test: SKIP (no emu at $EMU)"; exit 77; }
[ -f "$ROOT/dis/vid9p.dis" ] || { echo "vid9p_transport_test: SKIP (dis/vid9p.dis not built)"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -f "$ROOT"/.vid9p_tr.y4m "$ROOT"/.vid9p_tr.sh; rm -rf "$TMP"' EXIT

# 10 fps makes the pacing arithmetic round: pos = seconds * 10.
W=160; H=120; FPS=10; SECS=20
ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i "testsrc=size=${W}x${H}:rate=${FPS}:duration=${SECS}" \
    -c:v libx264 -pix_fmt yuv420p -g 20 "$TMP/clip.mp4" 2>/dev/null \
    || { echo "vid9p_transport_test: SKIP (ffmpeg lacks libx264)"; exit 77; }
"$VDEC" "$TMP/clip.mp4" --y4m "$ROOT/.vid9p_tr.y4m" --quiet

FAILED=0
fail() { echo "vid9p_transport_test: FAIL ($1)"; FAILED=1; }

# key <marker> <key>: value of key= on the line tagged <marker>.
key() { awk -v m="$1" -v k="$2" '$1 == m { for(i=2;i<=NF;i++){ n=index($i,"="); if(substr($i,1,n-1)==k) print substr($i,n+1) } }' "$TMP/out"; }

# ── static transport ────────────────────────────────────────
cat > "$ROOT/.vid9p_tr.sh" <<'ISH'
mkdir -p /mnt/video
mount {vid9p /.vid9p_tr.y4m} /mnt/video
sleep 2
echo M1 `{cat /mnt/video/0/status}
echo pause > /mnt/video/0/ctl
echo M2 `{cat /mnt/video/0/status}
sleep 1
echo M3 `{cat /mnt/video/0/status}
echo seek 5000 > /mnt/video/0/ctl
echo M4 `{cat /mnt/video/0/status}
echo seek +2000 > /mnt/video/0/ctl
echo M5 `{cat /mnt/video/0/status}
echo seek -4000 > /mnt/video/0/ctl
echo M6 `{cat /mnt/video/0/status}
echo play > /mnt/video/0/ctl
sleep 1
echo M7 `{cat /mnt/video/0/status}
echo stop > /mnt/video/0/ctl
echo M8 `{cat /mnt/video/0/status}
ISH
timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.vid9p_tr.sh > "$TMP/out" 2>&1

p1=$(key M1 pos); p2=$(key M2 pos); p3=$(key M3 pos)
[ -n "$p1" ] || { echo "vid9p_transport_test: FAIL (no status output)"; sed -n '1,10p' "$TMP/out"; exit 1; }
[ "$p1" -ge 12 ] && [ "$p1" -le 28 ] || fail "pacing: pos=$p1 after ~2s at ${FPS}fps"
[ "$(key M2 state)" = paused ]       || fail "pause: state=$(key M2 state)"
[ "$p3" = "$p2" ]                    || fail "pause holds: pos $p2 -> $p3"
[ "$(key M4 pos)" = 50 ]             || fail "seek 5000: pos=$(key M4 pos) want 50"
[ "$(key M4 t)" = 5000 ]             || fail "seek 5000: t=$(key M4 t) want 5000"
[ "$(key M5 pos)" = 70 ]             || fail "seek +2000: pos=$(key M5 pos) want 70"
[ "$(key M6 pos)" = 30 ]             || fail "seek -4000: pos=$(key M6 pos) want 30"
[ "$(key M7 state)" = playing ]      || fail "play resumes: state=$(key M7 state)"
p7=$(key M7 pos)
[ "$p7" -ge 36 ] && [ "$p7" -le 48 ]  || fail "resume pacing: pos=$p7 want ~40"
[ "$(key M8 pos)" = 0 ]              || fail "stop rewinds: pos=$(key M8 pos)"
[ "$(key M8 state)" = paused ]       || fail "stop pauses: state=$(key M8 state)"

# ── live retention window ───────────────────────────────────
cat > "$ROOT/.vid9p_tr.sh" <<ISH
mkdir -p /mnt/video
mount {vid9p -w 1 -c $VDEC $TMP/clip.mp4 --y4m - --quiet} /mnt/video
sleep 3
echo W1 \`{cat /mnt/video/0/status}
cat /mnt/video/0/frame > /dev/null
echo W2 expired=\$status
ISH
timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.vid9p_tr.sh > "$TMP/out" 2>&1

nf=$(key W1 frames); fb=$(key W1 first)
[ -n "$nf" ] || { echo "vid9p_transport_test: FAIL (no live status)"; sed -n '1,10p' "$TMP/out"; exit 1; }
# -w 1 at 10 fps = 10-frame window, trimmed in quarter-window chunks:
# retained stays within [window, window + chunk] of the 200-frame clip.
[ "$fb" -gt 0 ] || fail "window never trimmed (first=$fb)"
ret=$((nf - fb))
[ "$ret" -le 16 ] || fail "retained $ret frames, window is 10"
grep -q "frame expired" "$TMP/out" || fail "read below window did not error"

[ "$FAILED" -eq 0 ] && echo "vid9p_transport_test: PASS (transport verbs + retention window)" && exit 0
exit 1
