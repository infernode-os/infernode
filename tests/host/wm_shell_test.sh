#!/bin/sh
#
# wm_shell_test.sh — wm/shell (appl/wm/shell.b) under wm/wm with the SDL
# dummy driver, typed at through /dev/keyboard (tests/wm/shell.sh): a
# line sent and its output shown; ^D sending what is typed and, alone,
# end of file; ^P bringing back the last line; ^C discarding what is
# typed; ESC holding input until ESC again; raw mode while a program
# holds /dev/consctl, a key at a time and not echoed; /chan/shctl's
# commands; the window gone when the shell exits, nothing of it left
# running, and gone when a -c command is done.  Each step is checked
# in the transcript the window writes for Veltro
# (/tmp/veltro/shell/body).
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/shell.dis dis/read.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/wm_shell_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap 'rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/wm/shell.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
body() { cat "$ROOT/$T/body.$1" 2>/dev/null || true; }
# the number of lines of the step's transcript that are exactly $2
nlines() { body "$1" | grep -cx -- "$2" || true; }
windows() { sed -n "s/^R $1 *//p" "$LOG" | head -1; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -20 "$LOG"; exit 1; }
[ -n "$(windows start)" ] || fail "start: no window"

[ "$(nlines echo hello)" = 1 ] && pass "a line sent, its output shown" ||
	fail "echo: no line 'hello' in: $(body echo)"

if [ "$(nlines eof catdone)" = 1 ] && body eof | grep -q '^abc'; then
	pass "^D sends what is typed, and alone is end of file"
else
	fail "eof: cat not given abc then end of file: $(body eof)"
fi

[ "$(nlines history catdone)" = 2 ] && pass "^P brings back the last line" ||
	fail "history: 'catdone' not shown twice: $(body history)"

if [ "$(nlines discard kept)" = 1 ] && [ "$(nlines discard discarded)" = 0 ]; then
	pass "^C discards what is typed"
else
	fail "discard: $(body discard)"
fi

if [ "$(nlines holding held)" = 0 ] && [ "$(nlines released held)" = 1 ]; then
	pass "ESC holds what is typed until ESC again"
else
	fail "hold: held $(nlines holding held), released $(nlines released held)"
fi

if body raw | grep -q '^xgotraw' && [ "$(nlines cooked cooked)" = 1 ]; then
	pass "raw mode a key at a time, not echoed; cooked again after"
else
	fail "raw: $(body raw) / $(body cooked)"
fi

[ "$(nlines shctl 'shctl')" = 1 ] && pass "shctl takes cwd, button and clear" ||
	fail "shctl: $(body shctl)"

[ -z "$(windows exit)" ] && pass "the window goes when the shell exits" ||
	fail "exit: windows '$(windows exit)'"

# nothing of the window left running: its own procs (module Shell) and
# its theme watchers (Lucitheme) as they were before it
# (a status file has no newline: the occurrences are counted, not lines;
# arithmetic, as macOS's wc pads its count with blanks)
procs() { echo $(($(grep -o "$2" "$ROOT/$T/procs.$1" | wc -l))); }
if [ ! -f "$ROOT/$T/procs.after" ]; then
	fail "exit: no list of the processes after"
elif [ "$(procs after ' Shell')" = 0 ] && [ "$(procs after Lucitheme)" = "$(procs before Lucitheme)" ]; then
	pass "nothing of the window left running"
else
	fail "exit: left running: $(procs after ' Shell') Shell, $(procs after Lucitheme) Lucitheme (before: $(procs before Lucitheme))"
fi

if [ -n "$(windows cmd-running)" ] && [ -z "$(windows cmd-done)" ]; then
	pass "-c: the window goes when the command is done"
else
	fail "-c: windows '$(windows cmd-running)' then '$(windows cmd-done)'"
fi

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
grep -v '^R ' "$LOG" | tail -20
exit 1
