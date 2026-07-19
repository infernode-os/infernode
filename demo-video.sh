#!/bin/bash
#
# demo-video.sh — visible end-to-end demo of the InferNode video bridge
# (docs/H264-9P-BRIDGE.md): host vdec decode -> 9P (vid9p) -> Matrix
# video-pane composition + full-rate vidplay9p window.
#
# Opens the Lucifer GUI (skiplogon dev mode), mounts three feeds:
#   /mnt/video  — LIVE   vdec spawn, clipA.mp4 (1 fps, for the Matrix pane)
#   /mnt/videob — CANNED clipB.y4m static serve (loops in its Matrix pane)
#   /mnt/videoc — LIVE   vdec spawn, clipC.mp4 (25 fps, for vidplay9p)
# then launches wm/matrix on lib/matrix/compositions/video-demo and an
# oval-matte vidplay9p on the 25 fps feed.
#
# NB needs the amortised vid9p buffer growth (grow()/readall() fix in this
# tree): the original exact-fit reallocate-per-frame OOMed the Dis arena on
# any feed past ~100 frames, static or live.
#
# Regenerate media with:  (cd video-demo-media && see below)
#   ffmpeg -f lavfi -i "testsrc=size=320x240:rate=1:duration=180"  -c:v libx264 -pix_fmt yuv420p clipA.mp4
#   ffmpeg -f lavfi -i "testsrc2=size=320x240:rate=1:duration=60"  -c:v libx264 -pix_fmt yuv420p clipB.mp4
#   ffmpeg -f lavfi -i "testsrc2=size=320x240:rate=25:duration=30" -c:v libx264 -pix_fmt yuv420p clipC.mp4
#   ../tools/vdec/target/release/vdec clipB.mp4 --y4m clipB.y4m --quiet
#   ../tools/vdec/target/release/vdec clipC.mp4 --y4m clipC.y4m --quiet
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
VDEC="$ROOT/tools/vdec/target/release/vdec"
MEDIA="$ROOT/video-demo-media"

[ -x "$EMU" ]  || { echo "no emu at $EMU (copy or build one)"; exit 1; }
[ -x "$VDEC" ] || { echo "no vdec at $VDEC (cd tools/vdec && cargo build --release)"; exit 1; }
[ -f "$MEDIA/clipA.mp4" ] && [ -f "$MEDIA/clipB.y4m" ] && [ -f "$MEDIA/clipC.mp4" ] \
  || { echo "missing demo media in $MEDIA (see header comment)"; exit 1; }

# Inferno-side driver.  Launched AS wm/wm's initial command so the shell
# (and every app it starts) inherits a real wm draw context — matrix and
# vidplay9p need one and fall back to headless / bail without it.
# NB Inferno sh — no && / ||.  vid9p -c spawns the host command via the
# cmd device with its y4m stdout parsed live; a bare path is static mode.
DRIVER="
mkdir -p /tmp/matrix /mnt/video /mnt/videob /mnt/videoc
mount {vid9p -c $VDEC $MEDIA/clipA.mp4 --y4m - --quiet} /mnt/video
mount {vid9p /video-demo-media/clipB.y4m} /mnt/videob
mount {vid9p -c $VDEC $MEDIA/clipC.mp4 --y4m - --quiet} /mnt/videoc
echo demo: feeds mounted
wm/matrix /lib/matrix/compositions/video-demo &
echo demo: matrix launched
sleep 100000
"

exec "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
  wm/wm sh -c "$DRIVER"
