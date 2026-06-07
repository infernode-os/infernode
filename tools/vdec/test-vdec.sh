#!/usr/bin/env bash
#
# Headless validation of the vdec decode core.
#
# Generates an H.264 test clip, decodes it two ways — through vdec and through
# ffmpeg directly — and asserts the raw I420 output is byte-identical. Because
# both paths use the same libavcodec, any difference means vdec's stride-stripping
# / plane packing is wrong. Also leaves a watchable .y4m behind.
#
# Runnable on macOS (brew install ffmpeg@6) and Linux (apt ffmpeg). Mirrors the
# OS handling style of run-tests.sh / serve-llm.sh.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "test-vdec: need ffmpeg on PATH (macOS: brew install ffmpeg@6)" >&2
    exit 1
fi

W=320
H=240
N=30
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CLIP="$TMP/clip.mp4"

echo "test-vdec: building..."
cargo build --quiet
BIN="target/debug/vdec"

echo "test-vdec: generating ${W}x${H} H.264 testsrc ($N frames)..."
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=size=${W}x${H}:rate=30:duration=1" \
    -c:v libx264 -pix_fmt yuv420p -g 30 -frames:v "$N" "$CLIP"

echo "test-vdec: decoding via vdec -> y4m..."
"$BIN" "$CLIP" --y4m "$TMP/vdec.y4m" --quiet

# Normalise both decodes to headerless raw I420 for an exact byte compare.
ffmpeg -hide_banner -loglevel error -y -i "$TMP/vdec.y4m" \
    -f rawvideo -pix_fmt yuv420p "$TMP/vdec.i420"
ffmpeg -hide_banner -loglevel error -y -i "$CLIP" \
    -f rawvideo -pix_fmt yuv420p "$TMP/ref.i420"

framesz=$(( W * H * 3 / 2 ))
sz_vdec=$(wc -c < "$TMP/vdec.i420")
sz_ref=$(wc -c < "$TMP/ref.i420")
echo "test-vdec: frame size=${framesz}B  vdec=${sz_vdec}B  ref=${sz_ref}B"

fail=0
if [ "$sz_vdec" != "$sz_ref" ]; then
    echo "FAIL: decoded byte counts differ (frame count / packing mismatch)" >&2
    fail=1
elif cmp -s "$TMP/vdec.i420" "$TMP/ref.i420"; then
    echo "PASS: vdec I420 is byte-identical to ffmpeg ($(( sz_ref / framesz )) frames)"
else
    diffbytes=$(cmp -l "$TMP/vdec.i420" "$TMP/ref.i420" 2>/dev/null | wc -l || true)
    echo "FAIL: vdec I420 differs from ffmpeg in ${diffbytes} bytes" >&2
    fail=1
fi

exit "$fail"
