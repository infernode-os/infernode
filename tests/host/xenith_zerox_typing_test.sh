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
# backspace), and checks Xenith is still running with no text.type
# error. Needs the SDL GUI emulator: SKIP (77) on a headless build.

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
name="/n/local$d/t.md"
tag="$name Del Snarf | Look"
printf '%s' "$body" > "$d/t.md"
# one window on t.md in column 0 (dump id 1), its Zerox in column 1
{
    echo "/n/local$d"
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

out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c1 -g800x600 -r"$ROOT" /dis/sh.dis -c "
load std
bind '#U*' /n/local
xenith -l /n/local$d/xenith.dump &
sleep 6
echo before \`{ps | grep -i xenith | wc -l}
echo m 100 122 0 > /dev/pointer
sleep 1
for k in chars left c c chars left bs bs {
	cat /n/local$d/\$k > /dev/keyboard
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
if [ "$after" = "$before" ]; then
    echo "PASS: Xenith keeps running when typing beside a Zerox"
    exit 0
fi
echo "FAIL: Xenith processes $before before typing, '$after' after"
printf '%s\n' "$out" | sed 's/^/    /'
exit 1
