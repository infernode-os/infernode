#!/usr/bin/env bash
#
# #A/audiodev: enumerate host audio devices, select one by name, and say
# whether the capture that ran actually heard anything.
#
# The last part is the point. A device that opens and returns nothing but
# zeroes — a virtual input whose application is not running, an OS-muted
# device, a missing microphone authorization — is indistinguishable from a
# working microphone in a quiet room at every other layer.
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$ROOT"
export ROOT
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

EMU=${EMU:-./emu/MacOSX/o.emu}
TMPDIR_=${AUDIO_TEST_TMPDIR:-.omx/tmp}
mkdir -p "$TMPDIR_"
log="$TMPDIR_/audiodev-test.log"

skip() { echo "SKIP: $1"; exit 77; }
fail() { echo "FAIL: $1"; exit 1; }

run_inferno() {
  "$EMU" -r. /dis/sh.dis -c "$1" >"$log" 2>&1 || true
  cat "$log"
}

# 1. The file exists and enumerates. A backend without device selection
#    says so rather than pretending; that is a skip, not a failure.
run_inferno "bind -a '#A' /dev; cat /dev/audiodev" >/dev/null
if grep -q '^unsupported' "$log"; then
  skip "this build has no audio device selection (headless/non-SDL3 backend)"
fi
if grep -q '^unavailable' "$log"; then
  skip "the audio subsystem is unavailable in this host session"
fi
grep -q "^in selected " "$log" || fail "no input selection reported"
grep -q "^out selected " "$log" || fail "no output selection reported"

# 2. An unknown name is refused rather than silently ignored — otherwise a
#    typo leaves you on the wrong device with no signal.
run_inferno "bind -a '#A' /dev; echo 'in No Such Device Exists' > /dev/audiodev" >/dev/null
grep -q "no device of that name" "$log" ||
  fail "an unknown device name was accepted"

# 3. A name from the enumeration round-trips through the readback.
dev=$(run_inferno "bind -a '#A' /dev; cat /dev/audiodev" |
  awk -F"'" '/^in device /{print $2; exit}')
[ -n "$dev" ] || skip "no input devices on this host"
run_inferno "bind -a '#A' /dev; echo 'in $dev' > /dev/audiodev; cat /dev/audiodev" >/dev/null
grep -qF "in selected '$dev'" "$log" ||
  fail "selecting '$dev' did not read back"

# 3b. The exact line the readback produced is valid input — the
#     round-trip property the docs promise. The read emits
#     "in device 'X'"; write it back unchanged and expect the select.
#     (rc sh doubles quotes to embed a literal one.)
run_inferno "bind -a '#A' /dev; echo 'in device ''$dev''' > /dev/audiodev; cat /dev/audiodev" >/dev/null
grep -qF "in selected '$dev'" "$log" ||
  fail "writing back a read line ('in device '$dev'') was refused"

# 4. "default" returns to following the system default.
run_inferno "bind -a '#A' /dev; echo 'in $dev' > /dev/audiodev; echo 'in default' > /dev/audiodev; cat /dev/audiodev" >/dev/null
grep -q "^in selected default" "$log" ||
  fail "'in default' did not restore the system default"

# 5. A capture reports whether it heard anything. The capture file
#    lives under the emu root — /tmp does not exist inside the
#    emulator namespace, and a capture written nowhere leaves the
#    verdict 'capture idle' forever, testing nothing. With a real
#    path the verdict is asserted: 'active' and 'silent' are both
#    real answers (a silent-but-authorized room vs a muted or
#    virtual device), but 'idle' after a capture to a writable file
#    means the diagnostic never ran — that is a failure.
run_inferno "bind -a '#A' /dev; echo 'in rate 16000 chans 1 bits 16 enc pcm' > /dev/audioctl; dd -if /dev/audio -of /$TMPDIR_/audiodev-cap.pcm -bs 16000 -count 8; cat /dev/audiodev" >/dev/null
if grep -q "^capture active" "$log"; then
  echo "capture verdict: active"
elif grep -q "^capture silent" "$log"; then
  echo "SKIP: capture ran but heard only silence (no usable microphone here)"
elif grep -q "^capture idle" "$log"; then
  fail "capture wrote nothing to /$TMPDIR_/audiodev-cap.pcm; no verdict was reported"
else
  fail "no capture verdict reported after a capture"
fi

echo "PASS: audio devices enumerate, select by name, and report what they heard"
echo "PASS"
