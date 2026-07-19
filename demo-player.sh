#!/bin/bash
#
# demo-player.sh — the video-player crystallisation, self-contained.
# Serves a canned vdec-decoded clip (random access) through vid9p and
# loads lib/matrix/compositions/video-player: a Matrix video-pane as a
# transport-controlled player.
#
# Hover the pane, then: space = play/pause, s = stop, arrows = seek 5s.
#
# Media: video-demo-media/clipC.y4m (see demo-video.sh header to regenerate).
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
MEDIA="$ROOT/video-demo-media"

[ -x "$EMU" ]              || { echo "no emu at $EMU"; exit 1; }
[ -f "$MEDIA/clipC.y4m" ]  || { echo "missing $MEDIA/clipC.y4m"; exit 1; }

DRIVER="
mkdir -p /mnt/video
mount {vid9p /video-demo-media/clipC.y4m} /mnt/video
wm/matrix /lib/matrix/compositions/video-player &
sleep 100000
"

exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g900x600 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
