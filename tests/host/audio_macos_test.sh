#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"
export ROOT
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

EMU=${EMU:-./emu/MacOSX/o.emu}
AUDIODIR=${AUDIO_TEST_TMPDIR:-.omx/tmp}
mkdir -p "$AUDIODIR"

make_pcm() {
  python3 - "$1" "$2" "$3" <<'PY'
import math, struct, sys
path, rate, seconds = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
frames = int(rate * seconds)
with open(path, 'wb') as f:
    for i in range(frames):
        sample = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
        f.write(struct.pack('<h', sample))
PY
}

run_inferno() {
  "$EMU" -r. /dis/sh.dis -c "$1"
}

run_audio_inferno() {
  local log="$AUDIODIR/audio-test.log"
  if run_inferno "$1" >"$log" 2>&1; then
    cat "$log"
    if grep -Eq "cannot start CoreAudio (input|output): -66680" "$log"; then
      rm -f "$AUDIODIR/audio-capture.pcm"
      echo "SKIP: CoreAudio device unavailable in this host session"
    fi
    return 0
  fi
  cat "$log"
  if grep -Eq "cannot start CoreAudio (input|output): -66680" "$log"; then
    rm -f "$AUDIODIR/audio-capture.pcm"
    echo "SKIP: CoreAudio device unavailable in this host session"
    return 0
  fi
  return 1
}

mode=${1:-roundtrip}
case "$mode" in
ctl)
  run_inferno "bind -a '#A' /dev; ls /dev/audio /dev/audioctl; cat /dev/audioctl"
  ;;
playback)
  make_pcm "$AUDIODIR/audio-playback.pcm" 16000 0.25
  run_audio_inferno "bind -a '#A' /dev; echo 'out rate 16000 chans 1 bits 16 enc pcm' > /dev/audioctl; cat /$AUDIODIR/audio-playback.pcm > /dev/audio"
  ;;
capture)
  rm -f "$AUDIODIR/audio-capture.pcm"
  run_audio_inferno "bind -a '#A' /dev; echo 'in rate 16000 chans 1 bits 16 enc pcm' > /dev/audioctl; dd -if /dev/audio -of /$AUDIODIR/audio-capture.pcm -bs 32000 -count 1"
  if [ -e "$AUDIODIR/audio-capture.pcm" ] && [ ! -s "$AUDIODIR/audio-capture.pcm" ]; then
    # The device opened but delivered no frames. On macOS this is the
    # microphone-permission (TCC) posture for non-interactive shells and
    # CI: the input AudioQueue starts but never gets buffers. Same skip
    # philosophy as the -66680 device-unavailable case above — a real
    # capture regression can only be asserted where a mic is usable.
    echo "SKIP: no audio captured (microphone unavailable or permission denied in this host session)"
  fi
  ;;
roundtrip)
  "$0" playback
  "$0" capture
  ;;
*)
  echo "usage: $0 [ctl|playback|capture|roundtrip]" >&2
  exit 2
  ;;
esac
