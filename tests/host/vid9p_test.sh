#!/bin/bash
#
# vid9p_test.sh - end-to-end check that vid9p serves decoded frames over 9P
# byte-identically to the host decoder (INFR-266).
#
#   clip.mp4 --(vdec)--> .y4m --(vid9p in emu)--> /mnt/video/0/frame
#                                                       == ffmpeg's raw I420
#
# Prereqs: ffmpeg (with libx264), the vdec binary (build tools/vdec), the native
# limbo/mk toolchain's emu, and a built dis/vid9p.dis. SKIP (exit 77) if absent,
# per the harness convention (cf. INFR-34).
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

case "$(uname -s)" in
  Darwin) EMUHOST=MacOSX ;;
  Linux)  EMUHOST=Linux ;;
  *) echo "vid9p_test: SKIP (unsupported OS)"; exit 77 ;;
esac
EMU="$ROOT/emu/$EMUHOST/o.emu"

VDEC=""
for c in "$ROOT/tools/vdec/target/release/vdec" "$ROOT/tools/vdec/target/debug/vdec"; do
  [ -x "$c" ] && VDEC="$c" && break
done

command -v ffmpeg >/dev/null 2>&1 || { echo "vid9p_test: SKIP (no ffmpeg)"; exit 77; }
[ -n "$VDEC" ]        || { echo "vid9p_test: SKIP (no vdec binary; build tools/vdec)"; exit 77; }
[ -x "$EMU" ]         || { echo "vid9p_test: SKIP (no emu at $EMU)"; exit 77; }
[ -f "$ROOT/dis/vid9p.dis" ] || { echo "vid9p_test: SKIP (dis/vid9p.dis not built)"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -f "$ROOT"/.vid9p_test.y4m "$ROOT"/.vid9p_test.sh "$ROOT"/.vid9p_test.out; rm -rf "$TMP"' EXIT

W=160; H=120; N=10
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=${W}x${H}:rate=10:duration=1" \
    -c:v libx264 -pix_fmt yuv420p -g 5 -frames:v $N "$TMP/clip.mp4" 2>/dev/null \
    || { echo "vid9p_test: SKIP (ffmpeg lacks libx264)"; exit 77; }
"$VDEC" "$TMP/clip.mp4" --y4m "$ROOT/.vid9p_test.y4m" --quiet
ffmpeg -hide_banner -loglevel error -y -i "$TMP/clip.mp4" -f rawvideo -pix_fmt yuv420p "$TMP/ref.i420"

# Inferno-side: mount vid9p on the y4m and copy the frame stream back to the host.
cat > "$ROOT/.vid9p_test.sh" <<'ISH'
mkdir -p /mnt/video
mount {vid9p /.vid9p_test.y4m} /mnt/video
cat /mnt/video/0/frame > /.vid9p_test.out
ISH
# emu may idle after the script; timeout bounds it (the frame file is written first).
timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis /.vid9p_test.sh >/dev/null 2>&1

[ -f "$ROOT/.vid9p_test.out" ] || { echo "vid9p_test: FAIL (no frame output)"; exit 1; }
if cmp -s "$ROOT/.vid9p_test.out" "$TMP/ref.i420"; then
  echo "vid9p_test: PASS (/mnt/video/0/frame byte-identical to ffmpeg, $(wc -c < "$TMP/ref.i420") bytes)"
  exit 0
else
  echo "vid9p_test: FAIL (frame stream differs from ffmpeg)"
  exit 1
fi
