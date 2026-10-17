#!/bin/sh
#
# xenith_zerox_typing_test.sh — typing with a second window on the file.
#
# A Zerox (and so a Render beside its text) keeps its own copy of the
# characters being typed until they are committed. The arrow keys,
# Home, End, ^A, ^E and the other editing keys committed the typing
# window's copy alone; the other window's went stale, and the next
# character or backspace typed somewhere else tripped Text.type's
# consistency check ("text.type cq1", "text.type backspace"), whose
# error() takes Xenith down mid-edit.
#
# This loads a dump holding one file in two windows, types into the
# first through /dev/keyboard (characters, Left, more characters, a
# backspace), saves with ^S, and checks Xenith is still running with no
# text.type error and the file holds what was typed, once. Needs the
# SDL GUI emulator: SKIP (77) on a headless build.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "xenith_zerox_typing_test: SKIP (no emu)"; exit 77; }
if command -v nm >/dev/null 2>&1; then
    syms=$(nm "$EMU" 2>/dev/null)
    if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
        echo "xenith_zerox_typing_test: SKIP (headless emulator)"; exit 77
    fi
fi
[ -f "$ROOT/dis/xenith.dis" ] || { echo "xenith_zerox_typing_test: SKIP (Xenith not built)"; exit 77; }

d=$(mktemp -d "${TMPDIR:-/tmp}/xzt.XXXXXX")
d=$(cd "$d"; pwd -P)
trap 'rm -rf "$d"' EXIT

body='hello world
second line
'
name="/n$d/t.md"
tag="$name Del Snarf | Look"
# one window on t.md in column 0 (dump id 1), its Zerox in column 1
{
    echo "/n$d"
    echo /fonts/combined/go.14.font
    echo /fonts/combined/gomono.14.font
    printf '%11d %11d\n' 0 49
    printf 'F%11d %11d %11d %11d %11d %11d \n' 0 1 0 0 2 ${#body}
    printf '%11d %11d %11d %11d %11d %s\n' 1 ${#tag} ${#body} 0 1 "$tag"
    printf '%s' "$body"
    printf 'x%11d %11d %11d %11d %11d \n' 1 1 0 0 2
    printf '%11d %11d %11d %11d %11d %s\n' 2 ${#tag} ${#body} 0 1 "$tag"
} > "$d/xenith.dump"
printf 'ab' > "$d/chars"
printf '\356\200\224' > "$d/left"	# Keyboard->Left, U+E014
printf 'c' > "$d/c"
printf '\010' > "$d/bs"
printf '\023' > "$d/save"	# ^S: Put

out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -g800x600 -r"$ROOT" /dis/sh.dis -c "
load std
bind '#U*' /n	# /n is in every checkout; /n/local is made at run time
xenith -l /n$d/xenith.dump &
sleep 6
echo before \`{ps | grep -i xenith | wc -l}
echo m 100 122 0 > /dev/pointer
sleep 1
# t.md is not on disk yet: the dump holds its text, and Put makes it
for k in chars left c c chars left bs bs save {
	cat /n$d/\$k > /dev/keyboard
	sleep 1
}
echo after \`{ps | grep -i xenith | wc -l}
echo halt > /dev/sysctl" 2>&1)

before=$(printf '%s\n' "$out" | sed -n 's/^before *//p' | tr -d ' ')
after=$(printf '%s\n' "$out" | sed -n 's/^after *//p' | tr -d ' ')
if [ -z "$before" ] || [ "$before" = 0 ]; then
    echo "FAIL: Xenith did not start"
    printf '%s\n' "$out" | sed 's/^/    /'
    exit 1
fi
if printf '%s\n' "$out" | grep -q 'text\.type'; then
    echo "FAIL: typing beside a Zerox tripped Text.type's check"
    printf '%s\n' "$out" | sed 's/^/    /'
    exit 1
fi
if [ "$after" != "$before" ]; then
    echo "FAIL: Xenith processes $before before typing, '$after' after"
    printf '%s\n' "$out" | sed 's/^/    /'
    exit 1
fi
# ab, Left, cc, ab, Left, two backspaces
want='acbbhello world
second line'
got=$(cat "$d/t.md")
if [ "$got" != "$want" ]; then
    echo "FAIL: saved text is not what was typed"
    printf '    want: %s\n    got:  %s\n' "$(printf '%s' "$want" | head -1)" "$(printf '%s' "$got" | head -1)"
    exit 1
fi
echo "PASS: Xenith keeps running when typing beside a Zerox, and saves what was typed"
exit 0
