#!/bin/sh
#
# ftree_test.sh — wm/ftree under wm/wm, driven by keys, the pointer and
# its agent's ctl file (tests/ftree/drive.sh): the arrow keys move the
# selection and Right opens a folder (keyboard.h's keys; ftree matched
# X11 keysyms nothing sends), the agent's state file follows each change
# (it was written only on a click), refresh keeps what was open open, a
# bind made in ftree is in ftree's own name space (FORKNS, as
# upstream's) and not its parent's, Copy and Paste into copy a file into
# a folder, Remove asks and then removes a folder whole, and -d refuses
# a bind.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/ftree.dis dis/wm/wm.dis dis/lib/ftree/cptree.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

T=tmp/ftree_test.$$
D="$ROOT/$T"
mkdir -p "$D/tree/a" "$D/tree/b"
LOG=$(mktemp)
trap 'rm -f "$LOG"; rm -rf "$D"' EXIT
echo one > "$D/tree/a/a1.txt"
echo two > "$D/tree/b/b1.txt"
echo three > "$D/tree/c.txt"
cd "$ROOT"
SDL_VIDEODRIVER=dummy with_timeout 150 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/ftree/drive.sh /$T" </dev/null >"$LOG" 2>&1 || true

failed=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; failed=1; }
state() { sed -n "s/^R $1 *//p" "$LOG" | head -1; }
view() { sed -n "/^V $1\$/,/^[RV] /p" "$LOG" | sed '1d;$d'; }
selected() { state "$1" | sed -n 's/.*selected \([^ ]*\).*/\1/p'; }
items() { state "$1" | sed -n 's/.* items \([0-9]*\).*/\1/p'; }

if ! grep -q '^R done' "$LOG"; then
	bad "the drive did not finish"
	cat "$LOG"
	exit 1
fi

[ "$(selected clicked)" = "/$T/tree/c.txt" ] && ok "a click selects, and the state file says so" \
	|| bad "after the click the state says '$(selected clicked)'"
[ "$(selected up)" = "/$T/tree/b" ] && ok "Up moves the selection, and the state file follows" \
	|| bad "after Up the state says '$(selected up)'"
if [ "$(items right)" = 5 ] && view right | grep -q 'b1.txt'; then
	ok "Right opens the folder"
else
	bad "after Right: $(items right) items, view: $(view right | tr '\n' '|')"
fi
view refresh | grep -q 'b1.txt' && ok "refresh keeps the open folder open" \
	|| bad "refresh closed b: $(view refresh | tr '\n' '|')"

if view bound | grep -q 'a1.txt' && [ "$(state parent-b)" = "/$T/tree/b/b1.txt" ]; then
	ok "a bind shows in ftree and not in its parent's name space"
else
	bad "bind: ftree's view $(view bound | tr '\n' '|'), the parent's b: $(state parent-b)"
fi
[ "$(items unmounted)" = 5 ] && ok "unmount takes it away again" || bad "after unmount: $(items unmounted) items"

[ -f "$D/tree/a/c.txt" ] && [ "$(cat "$D/tree/a/c.txt")" = three ] && ok "Copy and Paste into copy the file" \
	|| bad "c.txt not copied into a"
[ "$(items asked)" = 5 ] && view asked | grep -q ' b/' && ok "Remove asks before removing" \
	|| bad "b removed before the answer"
[ ! -e "$D/tree/b" ] && ok "answered yes, Remove removes the folder whole" || bad "b still there"

[ ! -d "$D/tree/c.txt" ] && ! view disallowed | grep -q 'a1.txt' && grep -q 'not allowed (ftree -d)' "$LOG" &&
	ok "-d refuses a bind, and the ctl write says why" \
	|| bad "-d bound, or did not say why: $(view disallowed | tr '\n' '|')"

exit $failed
