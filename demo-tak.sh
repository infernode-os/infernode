#!/bin/bash
#
# demo-tak.sh — a live TAK/UAS video feed in the Matrix player.
#
# The perception node (default: hephaestus) runs manto, which ingests
# the UAS gimbal stream — the same feed nerv-gcs/ATAK gets — and
# re-serves annotated I420 over 9P (/mnt/vision, vid9p schema, port
# 6630 on localhost).  This rig tunnels that port over ssh, mounts it
# in a fresh emu, and loads the tak-uas crystallisation: the drone's
# view, with manto's detection boxes burned in, live in InferNode.
set -u
HOST="${1:-hephaestus}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
[ -x "$EMU" ] || { echo "no emu at $EMU"; exit 1; }

# One tunnel; tolerate an existing one on the port.
if ! nc -z 127.0.0.1 16630 2>/dev/null; then
  ssh -f -N -L 16630:127.0.0.1:6630 -o ExitOnForwardFailure=yes "$HOST" \
    || { echo "ssh tunnel to $HOST failed"; exit 1; }
fi

DRIVER='
mkdir -p /tmp/vision
mount -A tcp!127.0.0.1!16630 /tmp/vision
wm/matrix -g 1360x800 /lib/matrix/compositions/tak-uas &
sleep 100000
'
exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1400x860 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
