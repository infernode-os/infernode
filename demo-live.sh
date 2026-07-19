#!/bin/bash
#
# demo-live.sh — the video-live crystallisation, self-contained.
# Simulates two drone feeds as real-time-paced H.264 MPEG-TS over UDP
# (ffmpeg -re), has vid9p spawn the host vdec decoder on each udp:// URL,
# and loads lib/matrix/compositions/video-live: a two-pane live wall
# whose panes follow the live edge.
#
# Per-pane transport: arrows-back = DVR replay of the retained buffer,
# s = snap to live, space = pause.
#
# NB vid9p currently retains every decoded frame (random-access DVR), so
# a live feed's memory grows without bound: at 480x270/10fps x 2 feeds
# the 1 GB Dis heap lasts roughly 4 minutes.  Frame-window trimming is
# the flagged follow-up for long-running feeds (INFR-267 territory).
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
VDEC="$ROOT/tools/vdec/target/release/vdec"

[ -x "$EMU" ]  || { echo "no emu at $EMU"; exit 1; }
[ -x "$VDEC" ] || { echo "no vdec at $VDEC (cd tools/vdec && cargo build --release)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "needs ffmpeg"; exit 1; }

feed() { # $1 = lavfi source, $2 = port
  ffmpeg -hide_banner -loglevel error -re -stream_loop -1 \
    -f lavfi -i "$1=size=480x270:rate=10" \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 20 \
    -f mpegts "udp://127.0.0.1:$2" &
}

feed testsrc2 5004; FF1=$!
feed testsrc  5005; FF2=$!
trap 'kill $FF1 $FF2 2>/dev/null' EXIT
sleep 1

DRIVER="
mkdir -p /mnt/video /mnt/videob
mount {vid9p -c $VDEC udp://127.0.0.1:5004 --y4m - --quiet} /mnt/video
mount {vid9p -c $VDEC udp://127.0.0.1:5005 --y4m - --quiet} /mnt/videob
wm/matrix -g 800x600 /lib/matrix/compositions/video-live &
sleep 100000
"

"$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1100x500 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
