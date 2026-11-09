#!/bin/bash
#
# vid9p_replay_test.sh - vid9p -r: a .y4m file replayed as a live feed,
# a camera's stand-in where there is neither a camera nor a host decoder
# (a bare-metal board).  The feed says it is live (streaming, eof=0),
# gains frames at the file's rate, and goes on past the file's end from
# its first frame, numbered on: frame N is the file's frame N mod its
# length, byte for byte.
#
# Prereqs: ffmpeg, the emu and a built dis/vid9p.dis.  SKIP (exit 77) if
# absent.
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

case "$(uname -s)" in
  Darwin) EMUHOST=MacOSX ;;
  Linux)  EMUHOST=Linux ;;
  *) echo "vid9p_replay_test: SKIP (unsupported OS)"; exit 77 ;;
esac
EMU="$ROOT/emu/$EMUHOST/o.emu"

command -v ffmpeg >/dev/null 2>&1 || { echo "vid9p_replay_test: SKIP (no ffmpeg)"; exit 77; }
[ -x "$EMU" ] || { echo "vid9p_replay_test: SKIP (no emu at $EMU)"; exit 77; }
[ -f "$ROOT/dis/vid9p.dis" ] || { echo "vid9p_replay_test: SKIP (dis/vid9p.dis not built)"; exit 77; }

TMP="$(mktemp -d)"
P="$ROOT/.vid9p_replay_test"
trap 'rm -f "$P".*; rm -rf "$TMP"' EXIT

W=64; H=48; N=8; FSZ=$((W*H*3/2))
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=${W}x${H}:rate=10" \
    -frames:v $N -pix_fmt yuv420p "$P.y4m"
ffmpeg -hide_banner -loglevel error -y -i "$P.y4m" -f rawvideo -pix_fmt yuv420p "$TMP/ref.i420"
[ "$(wc -c < "$TMP/ref.i420")" -eq $((N*FSZ)) ] || { echo "vid9p_replay_test: FAIL (reference clip is not $N frames)"; exit 1; }

# frames 0, 8 and 13 of the feed: the file's 0, 0 (after the first
# loop) and 5 (13 mod 8)
cat > "$P.sh" <<ISH
load std
mount {vid9p -w 0 -r /.vid9p_replay_test.y4m} /mnt/video
cat /mnt/video/0/fmt > /.vid9p_replay_test.fmt
sleep 2
cat /mnt/video/0/status > /.vid9p_replay_test.st1
read -o 0 $FSZ < /mnt/video/0/frame > /.vid9p_replay_test.f0
read -o $((8*FSZ)) $FSZ < /mnt/video/0/frame > /.vid9p_replay_test.f8
read -o $((13*FSZ)) $FSZ < /mnt/video/0/frame > /.vid9p_replay_test.f13
cat /mnt/video/0/status > /.vid9p_replay_test.st2
echo halt > /dev/sysctl
ISH
timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis /.vid9p_replay_test.sh >"$TMP/emu.log" 2>&1

failed=0
fail() { echo "FAIL: $*"; failed=1; }

fmt=$(cat "$P.fmt" 2>/dev/null)
[ "$fmt" = "$W $H i420 10" ] && echo "PASS: fmt ($fmt)" || fail "fmt '$fmt', want '$W $H i420 10'"

st1=$(cat "$P.st1" 2>/dev/null)
case "$st1" in
streaming*eof=0*) echo "PASS: live (streaming, eof=0)" ;;
*) fail "status '$st1', want a live feed (streaming, eof=0)" ;;
esac
# about two seconds at 10 a second: paced, not read as fast as it can be
n=$(printf '%s\n' "$st1" | sed -n 's/.* frames=\([0-9]*\) .*/\1/p')
if [ -n "$n" ] && [ "$n" -ge 15 ] && [ "$n" -le 30 ]; then
	echo "PASS: paced at the file's rate ($n frames after 2 s)"
else
	fail "frames=$n after 2 s, want about 20 (10 a second)"
fi

frame() { dd if="$TMP/ref.i420" bs=$FSZ skip=$1 count=1 2>/dev/null; }
frame 0 > "$TMP/r0"; frame 5 > "$TMP/r5"
cmp -s "$P.f0" "$TMP/r0" && echo "PASS: frame 0 is the file's first" || fail "frame 0 differs from the file's first"
cmp -s "$P.f8" "$TMP/r0" && echo "PASS: frame 8 is the file's first again (looped)" || fail "frame 8 differs from the file's first"
cmp -s "$P.f13" "$TMP/r5" && echo "PASS: frame 13 is the file's frame 5" || fail "frame 13 differs from the file's frame 5"

st2=$(cat "$P.st2" 2>/dev/null)
n2=$(printf '%s\n' "$st2" | sed -n 's/.* frames=\([0-9]*\) .*/\1/p')
[ -n "$n2" ] && [ "$n2" -gt "$N" ] && echo "PASS: numbered on past the file's end ($n2 frames)" ||
	fail "frames=$n2, want more than the file's $N"

if [ $failed = 0 ]; then echo "vid9p_replay_test: ALL PASS"; exit 0; fi
tail -5 "$TMP/emu.log"
exit 1
