#!/bin/sh
#
# The keyboard on the screen's decoder and the files it is built on,
# gating (the Limbo suite's result does not gate): kbdecode_test (the
# word list, the layouts, taps and strokes read on QWERTY, Dvorak and
# Colemak), keyboards_test (/dev/keyboards, /dev/kbdin, /dev/fingers),
# and osk_accuracy_test, a simulated typist on each layout held to the
# accuracy bounds at its head: a change that makes typing worse fails
# here.  The headless emulator is enough.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/tests/kbdecode_test.dis dis/tests/keyboards_test.dis dis/tests/osk_accuracy_test.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
cd "$ROOT"
failed=0
for t in kbdecode_test keyboards_test osk_accuracy_test; do
	echo "--- $t ---"
	out=$(SDL_VIDEODRIVER=dummy with_timeout 900 "$EMU" -c1 -r"$ROOT" /dis/tests/$t.dis -v </dev/null 2>&1 || true)
	printf '%s\n' "$out" | grep -v '^fs:' | grep -E '^(--- |osk_accuracy:|PASS|FAIL|[0-9]+ passed)|    ' | grep -v ': .* typed .*, made\|stroke for' | tail -40
	if printf '%s\n' "$out" | grep -q '^PASS$'; then
		echo "PASS: $t"
	else
		echo "FAIL: $t"
		failed=1
	fi
done
[ $failed -eq 0 ] && echo "ALL PASS"
exit $failed
