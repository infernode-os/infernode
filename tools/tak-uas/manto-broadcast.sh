#!/bin/bash
# manto-broadcast — one encode of manto's annotated feed, fanned out to BOTH
# consumers: nerv-gcs (RFC4571 over TCP) and the emu (MPEG-TS over TCP, decoded
# locally by tools/vdec). This replaces the raw-I420-over-WAN 9P leg to the emu
# with a compressed stream.
#
# Encoder is software x264 (veryfast, tune=zerolatency); x264 at 720p10 is light
# on this box. NVENC (nvv4l2h264enc) is a follow-up.
#
# JOINER CORRECTNESS (the "non-existing PPS 0 referenced" / artefacts bug): the
# sinks MUST start a new/recovering client on a KEYFRAME, not the latest buffer.
# recover-policy=latest drops a fresh client mid-GOP with no preceding SPS/PPS,
# so the decoder can never resolve picture config and every consumer sees
# sustained corruption (and vdec eventually bails). This was misattributed to the
# encoder for a long time — it is a sink policy, identical for x264 and NVENC.
# Fix: sync-method=latest-keyframe (new clients begin at the last buffered
# keyframe, which carries inline SPS/PPS via h264parse config-interval=-1) +
# recover-policy=keyframe (slow clients resync to a keyframe, still non-blocking,
# so the stalled-client protection is preserved). buffers-max raised to 600 so a
# full GOP+keyframe is always retained to sync from. Verified: 2nd+ joins on a
# running feed decode with ZERO errors; the emu leg sustains instead of dying.
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
   ! videoconvert ! x264enc tune=zerolatency speed-preset=veryfast bitrate=8000 key-int-max=15 \
   ! h264parse config-interval=-1 ! tee name=t \
   t. ! queue leaky=downstream max-size-buffers=300 max-size-bytes=0 max-size-time=0 \
        ! rtph264pay pt=96 config-interval=1 ! rtpstreampay \
        ! tcpserversink host=127.0.0.1 port="$RFCPORT" sync=false sync-method=latest-keyframe buffers-max=600 recover-policy=keyframe timeout=10000000000 \
   t. ! queue leaky=downstream max-size-buffers=300 max-size-bytes=0 max-size-time=0 \
        ! mpegtsmux alignment=7 pat-interval=900 pmt-interval=900 si-interval=900 \
        ! tcpserversink host=127.0.0.1 port="$TSPORT" sync=false sync-method=latest-keyframe buffers-max=600 recover-policy=keyframe timeout=10000000000
