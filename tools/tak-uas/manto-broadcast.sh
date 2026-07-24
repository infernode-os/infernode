#!/bin/bash
# manto-broadcast — one encode of manto's annotated feed, fanned out to BOTH
# consumers: nerv-gcs (RFC4571 over TCP) and the emu (MPEG-TS over TCP, decoded
# locally by tools/vdec). This replaces the raw-I420-over-WAN 9P leg to the emu
# with a compressed stream.
#
# Encoder is software x264 (veryfast, tune=zerolatency): proven end-to-end for
# both consumers, incl. SPS/PPS repetition for mid-stream joiners. NVENC
# (nvv4l2h264enc) works for raw encoding on this box but its SPS/PPS handling
# for late joiners needs more work (RFC4571 + TS joiners get "non-existing PPS"
# / "unspecified size") — tracked as a follow-up; x264 at 720p10 is light here.
#
# Usage: manto-broadcast.sh [feed-id] [rfc4571-port] [ts-port]   (default gz-uas 5601 5602)
set -u
unset DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE 2>/dev/null
N=/mnt/orin-ssd/pdfinn/github.com/NERVsystems/nerva3
FEED="${1:-gz-uas}"; RFCPORT="${2:-5601}"; TSPORT="${3:-5602}"
W=1280; H=720; FPS=10; FRAMESIZE=$((W*H*3/2))

exec "$N/emu/Linux/o.emu" -r"$N" sh -c "mkdir -p /tmp/vb; mount -A tcp!127.0.0.1!6630 /tmp/vb; cat /tmp/vb/feeds/$FEED/frame" \
 | gst-launch-1.0 -q fdsrc fd=0 do-timestamp=true blocksize="$FRAMESIZE" \
   ! rawvideoparse format=i420 width="$W" height="$H" framerate="$FPS"/1 \
   ! videoconvert ! x264enc tune=zerolatency speed-preset=veryfast bitrate=8000 key-int-max=15 intra-refresh=true \
   ! h264parse config-interval=-1 ! tee name=t \
   t. ! queue leaky=downstream max-size-buffers=300 max-size-bytes=0 max-size-time=0 \
        ! rtph264pay pt=96 config-interval=1 ! rtpstreampay \
        ! tcpserversink host=127.0.0.1 port="$RFCPORT" sync=false \
   t. ! queue leaky=downstream max-size-buffers=300 max-size-bytes=0 max-size-time=0 \
        ! mpegtsmux alignment=7 pat-interval=900 pmt-interval=900 si-interval=900 \
        ! tcpserversink host=127.0.0.1 port="$TSPORT" sync=false
