#!/bin/bash
# select-vehicle.sh <1|2|3> — route the SELECTED vehicle gimbal into the
# perception pipeline. manto streams one feed at a time (manto#4), so the
# selected bird camstream feeds the single ingest (heph:5610); the phone
# (RFC4571 :5601) and the emu spectator (:5602) then both follow the
# selected vehicle, manto boxes included. MAVLink needs no switching —
# the roster carries all three sysids; pick the vehicle in the plugin UI
# and run me to match the video.
set -u
case "${1:?vehicle 1|2|3}" in
  1) M=iris_with_gimbal;; 2) M=iris_b;; 3) M=iris_c;; *) echo "vehicle 1|2|3"; exit 2;;
esac
pkill -x gz_cam_stream 2>/dev/null   # pipe collapse takes the gst with it
sleep 2
setsid nohup bash "$HOME/nerva-sim/camstream/camstream-fleet.sh" "$M" 5610 \
  </dev/null >/tmp/camstream.log 2>&1 &
sleep 3
pgrep -x gz_cam_stream >/dev/null \
  && echo "video source -> vehicle $1 ($M); manto reconnects in ~5 s, phone+emu follow" \
  || echo "FAILED — /tmp/camstream.log"
