#!/bin/bash
#
# demo-tak.sh — a live TAK/UAS video feed in the Matrix player, over the
# COMPRESSED edge leg (the shape closest to a real deployment).
#
# The perception node (default: hephaestus) runs manto, which ingests the
# UAS gimbal stream, YOLO-annotates it, and — via ~/bin/manto-broadcast.sh
# — encodes it ONCE and fans it out as H.264: RFC4571 on :5601 to nerv-gcs,
# and MPEG-TS on :5602 for remote observers.  This rig tunnels the :5602
# TCP stream, decodes it LOCALLY with tools/vdec (ffmpeg) served through
# vid9p, and shows it in the emu.  The WAN carries compressed video, not
# the raw ~41 MB/s I420 of the old direct-9P mount (kept as demo-tak-raw.sh).
set -u
HOST="${1:-hephaestus}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
VDEC="$ROOT/tools/vdec/target/release/vdec"
[ -x "$EMU" ]  || { echo "no emu at $EMU"; exit 1; }
[ -x "$VDEC" ] || { echo "no vdec at $VDEC (cd tools/vdec && cargo build --release)"; exit 1; }

# One tunnel for the compressed TS; tolerate an existing one on the port.
if ! nc -z 127.0.0.1 5602 2>/dev/null; then
  ssh -f -N -L 5602:127.0.0.1:5602 -o ExitOnForwardFailure=yes "$HOST" \
    || { echo "ssh tunnel to $HOST failed"; exit 1; }
fi

# vid9p spawns the host vdec decoder on the tcp:// stream and serves the
# decoded frames as /tmp/vision/0 (vid9p fmt/frame schema).
DRIVER='
mkdir -p /tmp/vision
mount {vid9p -c '"$VDEC"' tcp://127.0.0.1:5602 --y4m - --quiet} /tmp/vision
wm/matrix -g 1360x800 /lib/matrix/compositions/tak-uas-live &
sleep 100000
'
exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1400x860 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
