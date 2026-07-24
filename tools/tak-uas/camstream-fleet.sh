#!/bin/bash
# camstream-fleet.sh <model-name> <dest-port>
#  vehicle 1: camstream-fleet.sh iris_with_gimbal 5610
#  vehicle 2: camstream-fleet.sh iris_b 5620   (nested gimbal_b)
#  vehicle 3: camstream-fleet.sh iris_c 5630   (nested gimbal_c)
set -u
export GZ_VERSION=harmonic
M="${1:?model name}"; PORT="${2:?dest port}"
case "$M" in
  iris_b) G=gimbal_b;; iris_c) G=gimbal_c;; *) G=gimbal;;
esac
B="/world/iris_runway_targets/model/$M/model/$G/link/pitch_link/sensor/camera/image"
BIN="$HOME/nerva-sim/camstream/gz_cam_stream"
"$BIN" "$B" 1280 720 \
 | gst-launch-1.0 -q fdsrc fd=0 blocksize=2764800 \
   ! rawvideoparse format=rgb width=1280 height=720 framerate=10/1 \
   ! videoconvert ! x264enc bitrate=6000 speed-preset=veryfast tune=zerolatency key-int-max=15 \
   ! rtph264pay pt=96 config-interval=1 \
   ! udpsink host=10.147.17.120 port="$PORT" sync=false
