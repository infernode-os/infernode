#!/bin/sh
#
# editor_ui_test.sh — wm/editor under wm/wm (tests/wm/editor.sh), typed
# into through /chan/uitest while a client changes it through /edit and
# the Veltro editor tool through /tmp/veltro/editor: undo of a client's
# change (it crashed the editor), a body longer than one 9P message
# (only its last part was kept), open, new and quit refused over
# changes not saved, a save that fails, the tool's write undone and its
# answers, wm's Delete keeping changes not saved the first time, a new
# file named on the command line.
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/editor.dis dis/veltro/tools9p.dis dis/veltro/tools/editor.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

W=$(mktemp -d)
LOG=$W/log
trap 'rm -rf "$W"' EXIT
# longer than one 9P message, with characters of two, three and four
# bytes falling where the messages divide it
python3 -I - "$W/big.txt" <<'PY'
import sys
lines = ['line %d ' % i + 'é漢\U0001F680' * (i % 5) + 'x' * (i * 7 % 81) for i in range(400)]
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY

cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c '#U*$W' /tmp; path=(/dis/veltro /dis/cmd /dis .); wm/wm sh /tests/wm/editor.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
for c in typed undo-insert undo-typing undone-clean redo big-body \
	open-dirty new-dirty quit-dirty kept save-error save-error-name \
	tool-write tool-wrote tool-undone tool-append tool-open-dirty \
	delete-kept delete-again new-file saved-clean; do
	got=$(sed -n "s/^R $c //p" "$LOG" | head -1)
	if [ "$got" = ok ]; then
		echo "PASS: $c"
	elif [ -z "$got" ]; then
		echo "FAIL: $c: never reached"; failed=1
	else
		echo "FAIL: $c: $got"; failed=1
	fi
done
if [ $failed = 0 ]; then echo "editor_ui_test: PASS"; exit 0; fi
grep -v '^R ' "$LOG" | tail -20
exit 1
