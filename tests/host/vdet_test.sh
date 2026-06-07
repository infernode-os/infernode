#!/bin/bash
#
# vdet_test.sh - the host video detector emits one well-formed detection record
# per decoded frame (INFR-277 prototype).
#
# Prereqs: ffmpeg (with libx264) and the vdet binary (build tools/vdet). SKIP
# (exit 77) if absent. Does NOT need emu or the cmd device — that 9P relay is
# exercised by the vision9p path separately.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

VDET=""
for c in tools/vdet/target/release/vdet tools/vdet/target/debug/vdet; do
  [ -x "$ROOT/$c" ] && VDET="$ROOT/$c" && break
done
command -v ffmpeg >/dev/null 2>&1 || { echo "vdet_test: SKIP (no ffmpeg)"; exit 77; }
[ -n "$VDET" ]        || { echo "vdet_test: SKIP (no vdet binary; build tools/vdet)"; exit 77; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
N=12
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=160x120:rate=12:duration=1" \
    -c:v libx264 -pix_fmt yuv420p -g 6 -frames:v $N "$TMP/clip.mp4" 2>/dev/null \
    || { echo "vdet_test: SKIP (ffmpeg lacks libx264)"; exit 77; }

"$VDET" "$TMP/clip.mp4" --thresh 200 > "$TMP/out" 2>/dev/null
lines=$(wc -l < "$TMP/out")

# Every record must be "frame <i> pts=<..>ms ..." with i counting 0..N-1.
ok=1; i=0
while read -r tag idx pts _rest; do
  [ "$tag" = "frame" ] || ok=0
  [ "$idx" = "$i" ]    || ok=0
  case "$pts" in pts=*ms) ;; *) ok=0 ;; esac
  i=$((i+1))
done < "$TMP/out"

if [ "$lines" -eq "$N" ] && [ "$i" -eq "$N" ] && [ "$ok" -eq 1 ]; then
  echo "vdet_test: PASS ($N frames -> $N detection records)"
  exit 0
else
  echo "vdet_test: FAIL (lines=$lines i=$i ok=$ok expected=$N)"
  sed -n '1,3p' "$TMP/out" >&2
  exit 1
fi
