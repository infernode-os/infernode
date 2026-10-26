#!/bin/sh
#
# shell_ui_test.sh — wm/shell under wm/wm (tests/wm/shell.sh), typed
# into through /chan/uitest: lines typed while a command runs run after
# it in their order (they ran last first), Ctrl-C kills what the shell
# runs and the shell goes on, the rest of its line not run (it sent DEL
# bytes into the next command), and the line after it is the shell's
# when what was killed was reading the console,
# output whose characters are divided between writes kept whole, a
# flood of output typed into, history and Ctrl-U.
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/shell.dis dis/sh.dis; do
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
# longer than one write of cat, with characters of two, three and four
# bytes falling where the writes divide it
python3 -I - "$W/big.txt" <<'PY'
import sys
lines = ['line %d ' % i + 'é漢\U0001F680' * (i % 5) + 'x' * (i * 7 % 81) for i in range(400)]
open(sys.argv[1], 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
PY

cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 120 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c '#U*$W' /tmp; wm/wm sh /tests/wm/shell.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
for c in hello typeahead interrupt interrupt-killed interrupt-read utf utf-lines flood history ctrl-u; do
	got=$(sed -n "s/^R $c //p" "$LOG" | head -1)
	if [ "$got" = ok ]; then
		echo "PASS: $c"
	elif [ -z "$got" ]; then
		echo "FAIL: $c: never reached"; failed=1
	else
		echo "FAIL: $c: $got"; failed=1
	fi
done
if [ $failed = 0 ]; then echo "shell_ui_test: PASS"; exit 0; fi
grep -v '^R ' "$LOG" | tail -20
exit 1
