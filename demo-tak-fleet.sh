#!/bin/bash
#
# demo-tak-fleet.sh — the three-vehicle UAS spectate wall.
#
# Tunnels the perception node's three per-feed MPEG-TS broadcasts
# (:5602/:5604/:5606 — manto-annotated, one x264 encode each), decodes
# each locally with tools/vdec via vid9p (bounded ring, -w 12), and
# loads the tak-uas-fleet crystallisation: three live panes + transport.
# Fleet bring-up on the sim side: minipc sim-up-fleet.sh + camstream-fleet
# ×3; per-feed broadcasts on the perception node (manto-broadcast.sh
# gz-uas-b 5603 5604, gz-uas-c 5605 5606).  Single-vehicle rig stays
# demo-tak.sh.
set -u
HOST="${1:-hephaestus}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
VDEC="$ROOT/tools/vdec/target/release/vdec"
[ -x "$EMU" ]  || { echo "no emu at $EMU"; exit 1; }
[ -x "$VDEC" ] || { echo "no vdec at $VDEC (cd tools/vdec && cargo build --release)"; exit 1; }

for p in 5602 5604 5606; do
  nc -z 127.0.0.1 "$p" 2>/dev/null || \
    ssh -f -N -L "$p:127.0.0.1:$p" -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 "$HOST" \
      || { echo "tunnel $p to $HOST failed"; exit 1; }
done

DRIVER='
mkdir -p /tmp/vision /tmp/visionb /tmp/visionc
mount {vid9p -w 12 -c '"$VDEC"' tcp://127.0.0.1:5602 --y4m - --quiet} /tmp/vision
mount {vid9p -w 12 -c '"$VDEC"' tcp://127.0.0.1:5604 --y4m - --quiet} /tmp/visionb
mount {vid9p -w 12 -c '"$VDEC"' tcp://127.0.0.1:5606 --y4m - --quiet} /tmp/visionc
wm/matrix -g 1360x820 /lib/matrix/compositions/tak-uas-fleet &
sleep 100000
'
exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1400x880 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
