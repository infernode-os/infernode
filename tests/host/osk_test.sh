#!/bin/sh
#
# wm/osk under wm/wm, typed on through /dev/fingers into a wm/shell
# (tests/osk/drive.sh): it docks along the bottom of the screen and
# the shell keeps the keyboard; taps type, the words offered mid-word,
# shift is one capital, a slip
# onto the key beside is put right when the word ends and a delete
# straight after takes the correction back; two fingers down at once
# type in the order they landed; a mouse's click types; a stroke
# through a word's letters types the word; the symbols; in plain mode
# nothing is put right; Dvorak's keys, the layout kept for next time;
# the keys go to the window clicked in last (a wm/editor, then the
# shell), by finger and by the mouse, whichever window the mouse crossed
# on its way to them; a swipe down hides it to a handle, a touch on the
# handle shows it.
# Needs the SDL emulator (SDL_VIDEODRIVER=dummy) and the word list.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/shell.dis dis/wm/osk.dis dis/lib/kbdecode.dis lib/osk/en.words; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/osk_test.$$
mkdir -p "$ROOT/$T"
LOG="$ROOT/$T/log"
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 240 "$EMU" -c1 -pheap=512m -pimage=512m -g800x480 -r"$ROOT" \
	/dis/sh.dis -c "bind -c /$T /tmp; wm/wm sh /tests/osk/drive.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
# the last line the shell printed before its prompt, at a step
out() { grep -v '^;' "$ROOT/$T/body.$1" 2>/dev/null | tail -1; }
st() { sed -n "s/^$2 //p" "$ROOT/$T/status.$1" 2>/dev/null; }
windows() { sed -n "s/^R $1 *//p" "$LOG" | head -1; }

grep -q '^R done' "$LOG" || { fail "the driver did not finish"; tail -20 "$LOG"; exit 1; }

# the keyboard: the topmost window, along the bottom, the screen's width
set -- $(windows start)
if [ $# -ge 10 ] && [ "$2" = 0 ] && [ "$4" = 800 ] && [ "$5" = 480 ] && [ "$3" -gt 200 ]; then
	pass "docked along the bottom, above the shell"
else
	fail "start: windows $(windows start)"
fi
[ "$(st start state)" = shown ] && pass "shown" || fail "start: state $(st start state)"

check() {	# step want what
	got=$(out "$1")
	[ "$got" = "$2" ] && pass "$3" || fail "$3: '$got', not '$2'"
}
check hello hello "taps type into the window with the keyboard"
if grep -qx '"keybo"' "$ROOT/$T/suggestions" 2>/dev/null && grep -qx 'keyboard' "$ROOT/$T/suggestions"; then
	pass "the words offered mid-word: what was typed, and the word it begins"
else
	fail "suggestions for keybo: $(tr '\n' ' ' < "$ROOT/$T/suggestions" 2>/dev/null)"
fi
check keyboard keyboard "the word finished"
check shift Hey "shift: one capital"
check slip hello "a slip onto the key beside put right"
check undo teh "a correction taken back by a delete straight after"
check rollover ab "two fingers down at once type in the order they landed"
check mouse z "a mouse's click types"
check echo q "a finger's tap, its pointer press read first, types once"
check swipe hello "a stroke through a word's letters types it"
# the keys after the swipe as they were before it: no trail left on them
if command -v python3 >/dev/null; then
	same=$(python3 - "$ROOT" "$T" <<'PY'
import sys, os
root, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, 'tools'))
import p9img2png as P
d = os.path.join(root, T)
try:
    a = P.load(os.path.join(d, 'keys.before.img'))
    b = P.load(os.path.join(d, 'keys.after.img'))
except Exception as e:
    print('none', e); sys.exit(0)
ks = [l.split() for l in open(os.path.join(d, 'qwerty.keys')) if len(l.split()) == 5]
y0 = min(int(k[2]) for k in ks); y1 = max(int(k[4]) for k in ks)
x0 = min(int(k[1]) for k in ks); x1 = max(int(k[3]) for k in ks)
n = diff = 0
for y in range(y0, y1, 2):
    for x in range(x0, x1, 2):
        n += 1
        if a.px(x, y) != b.px(x, y):
            diff += 1
print(diff, n)
PY
)
	set -- $same
	if [ "${1:-none}" = none ]; then
		fail "the keys before and after the swipe were not captured: $same"
	elif [ "$1" -eq 0 ]; then
		pass "the swipe's trail goes when the finger lifts"
	else
		fail "the swipe's trail left on the keys: $1 of $2 points changed"
	fi
fi
check symbols 42 "the symbols"
check plain teh "plain: nothing put right"
got=$(out dvorak)
if [ "$got" = Dvorak ] || [ "$got" = dvorak ]; then
	pass "Dvorak's keys"
else
	fail "dvorak: '$got'"
fi
if cmp -s "$ROOT/$T/qwerty.keys" "$ROOT/$T/dvorak.keys"; then
	fail "the keys did not change with the layout"
else
	pass "the keys file follows the layout"
fi
grep -qx dvorak "$ROOT/$T/savedlayout" 2>/dev/null && pass "the layout kept for next time" ||
	fail "layout kept: $(cat "$ROOT/$T/savedlayout" 2>/dev/null)"
# the keys to the window clicked in last, not the one the mouse crossed
eb=$(tr -d '\n' < "$ROOT/$T/editor.body" 2>/dev/null)
[ "$eb" = xyz ] && pass "to the editor clicked in, by finger and by the mouse over the shell" ||
	fail "to the editor: its body '$eb', the shell '$(out toeditor)'"
eb2=$(tr -d '\n' < "$ROOT/$T/editor.body2" 2>/dev/null)
[ "$(out toshell)" = focus ] && [ "$eb2" = xyz ] &&
	pass "to the shell clicked in, by the mouse over the editor" ||
	fail "to the shell: '$(out toshell)', the editor '$eb2'"
[ "$(st hidden state)" = handle ] && pass "a swipe down hides it to a handle" ||
	fail "hidden: state $(st hidden state)"
set -- $(windows hidden)
[ $# -ge 5 ] && [ $(($5 - $3)) -lt 60 ] && pass "the handle is a strip" || fail "hidden: windows $(windows hidden)"
[ "$(st shownagain state)" = shown ] && pass "a touch on the handle shows it" ||
	fail "shown again: state $(st shownagain state)"

if [ $failed -ne 0 ]; then
	echo "--- log"
	grep -v '^fs:' "$LOG" | tail -30
	exit 1
fi
echo "ALL PASS"
