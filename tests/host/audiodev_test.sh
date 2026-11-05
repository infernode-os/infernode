#!/bin/sh
#
# audiodev_test.sh — the shared audio device (#A, emu/port/devaudio.c)
# with the emulator's fake hardware ($INFERNODE_AUDIO_FAKE): runs
# tests/audiodev_test.b, which reads back what the speaker played
# (#A/fakeout) and writes the microphone (#A/fakein).  Streams from
# #A/mix/new; two formats mixed, each heard at its level; two writers of
# #A/audio mixed, not interleaved; media ducked under speech and back;
# the microphone whole to two readers in two formats; a writer paced by
# the speaker, or never waiting with only its newest kept; a close
# drained; ctl read back and bad lines refused whole.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/audiodev_test.dis" ] || { echo "SKIP: tests/audiodev_test.dis not built"; exit 77; }

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
cd "$ROOT"
INFERNODE_AUDIO_FAKE=1 SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -r"$ROOT" \
	/tests/audiodev_test.dis -v </dev/null >"$LOG" 2>&1 || true
grep -E '^(=== RUN|--- (PASS|FAIL|SKIP))|^    ' "$LOG" | grep -v '^    [A-Za-z]*: [0-9]*$' || true
if grep -q '^--- FAIL' "$LOG" || ! grep -q '^PASS$' "$LOG"; then
	echo "FAIL: audiodev_test"
	tail -5 "$LOG"
	exit 1
fi
grep -q '^--- SKIP' "$LOG" && { echo "FAIL: the fake hardware was not there"; exit 1; }
echo "PASS: audiodev_test"
