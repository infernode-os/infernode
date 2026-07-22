#!/bin/bash
#
# demo-overlay.sh — video with live annotations: a canned clip through
# vid9p and a synthetic "tracker" writing moving detection boxes into
# the vision tree, drawn anti-aliased over the frames by the
# video-overlay module (frame coords; /mnt/video/0 -> /mnt/vision/0).
#
# The tracker runs HERE on the host: the emu root is this directory,
# so mnt/vision/0/boxes IS /mnt/vision/0/boxes inside — any process,
# host or emu or agent, can feed annotations the same way.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
MEDIA="$ROOT/video-demo-media"
[ -x "$EMU" ]             || { echo "no emu at $EMU"; exit 1; }
[ -f "$MEDIA/clipC.y4m" ] || { echo "missing $MEDIA/clipC.y4m"; exit 1; }

mkdir -p "$ROOT/mnt/vision/0"
( while :; do
    for x in 20 60 100 140 180 140 100 60; do
      echo "$x 60 $((x+100)) 160 TRACK-1" > "$ROOT/mnt/vision/0/boxes"
      sleep 1
    done
  done ) &
TRK=$!
trap 'kill $TRK 2>/dev/null' EXIT

DRIVER='
mkdir -p /mnt/video
mount {vid9p /video-demo-media/clipC.y4m} /mnt/video
wm/matrix -g 800x600 /lib/matrix/compositions/video-overlay &
sleep 100000
'
"$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g900x600 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
