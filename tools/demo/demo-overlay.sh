#!/bin/bash
#
# demo-overlay.sh — video with live annotations: a canned clip through
# vid9p and a synthetic "tracker" rewriting a layer file of one moving
# box, bound into the feed's layer/ directory and drawn over the frames
# by the video-overlay module (layers(2), #1095).
#
# The tracker runs HERE on the host: the emu root is this directory, so
# tmp/demo-overlay/track IS /tmp/demo-overlay/track inside, and the
# driver binds that directory onto /mnt/video/0/layer.  Any process,
# host or emu or agent, can add a layer the same way: write records
# (layers(2)) into a file and bind its directory there; unmount it and
# it is gone.  Detections from vision(4) are a layer as they come:
#   bind -a /mnt/vision/1/layer /mnt/video/0/layer
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
case "$(uname)" in
Darwin) EMU="$ROOT/emu/MacOSX/o.emu" ;;
*)      EMU="$ROOT/emu/Linux/o.emu" ;;
esac
MEDIA="$ROOT/video-demo-media"
[ -x "$EMU" ]             || { echo "no emu at $EMU"; exit 1; }
[ -f "$MEDIA/clipC.y4m" ] || { echo "missing $MEDIA/clipC.y4m"; exit 1; }

T="$ROOT/tmp/demo-overlay"
mkdir -p "$T"
( while :; do
    for x in 20 60 100 140 180 140 100 60; do
      echo "frame=* box x0=$x y0=60 x1=$((x+100)) y1=160 label=TRACK-1" > "$T/track.new"
      mv "$T/track.new" "$T/track"
      sleep 1
    done
  done ) &
TRK=$!
trap 'kill $TRK 2>/dev/null' EXIT

DRIVER='
mkdir -p /mnt/video
mount {vid9p /video-demo-media/clipC.y4m} /mnt/video
bind -a /tmp/demo-overlay /mnt/video/0/layer
wm/matrix -g 800x600 /lib/matrix/compositions/video-overlay &
sleep 100000
'
"$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g900x600 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
