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

# An open that fails while the driver can still see devices is a real
# regression, not an unusable host: the audio subsystem came up with an
# empty device list. The device-less case stays a skip.
assert_devices_or_skip() {
  if grep -q "devices present: yes" "$1"; then
    echo "FAIL: audio open failed while the driver reports devices"
    return 1
  fi
  return 0
}

run_audio_inferno() {
  local log="$AUDIODIR/audio-test.log"
  if run_inferno "$1" >"$log" 2>&1; then
    cat "$log"
    assert_devices_or_skip "$log" || return 1
    return 0
  fi
  cat "$log"
  assert_devices_or_skip "$log" || return 1
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
  if [ ! -s "$AUDIODIR/audio-capture.pcm" ]; then
    # The device opened but delivered no frames. On macOS this is the
    # microphone-permission (TCC) posture for non-interactive shells and
    # CI: the input AudioQueue starts but never gets buffers. A real
    # capture regression can only be asserted where a mic is usable.
    echo "SKIP: no audio captured (microphone unavailable or permission denied in this host session)"
    exit 77
  fi
  # A capture that delivered 738 of 32000 bytes must not pass the same
  # check as a healthy one: assert a floor of 0.25 s at 16 kHz mono s16.
  capsize=$(wc -c < "$AUDIODIR/audio-capture.pcm" | tr -d ' ')
  if [ "$capsize" -lt 8000 ]; then
    echo "FAIL: capture delivered only ${capsize} of 32000 bytes"
    exit 1
  fi
  echo "capture delivered ${capsize} of 32000 bytes"
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
