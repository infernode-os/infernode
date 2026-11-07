#!/bin/sh
#
# wm_cursor_test.sh — wm/wm's cursors reach the screen: New from the
# menu makes the cross SDL's cursor, the sweep gives the arrow back, and
# Delete's gunsight comes and goes the same way.  Each must be made on
# the main thread, the only one SDL allows cursor calls on: emu made
# them on the thread that wrote /dev/cursor, and on macOS the cursor
# could be lost (the cross never showed after New).  A move written to
# /dev/pointer warps the host's pointer, on the main thread too.
#
# wm/wm (appl/wm/wm.b) runs under the SDL dummy driver, driven by
# tests/wm/cursor.sh; a shim preloaded into emu (tests/wm/cursorshim.c)
# logs each cursor call and warp, which cursor (its mask bits) and which
# thread.
# Linux only: it needs LD_PRELOAD.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ "$EMUHOST" = Linux ] || { echo "SKIP: the cursor shim needs LD_PRELOAD (Linux)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/wm.dis dis/wm/sh.dis dis/lib/menuhit.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CC=$(command -v cc || command -v gcc || command -v clang || true)
[ -n "$CC" ] || { echo "SKIP: no C compiler for the shim"; exit 77; }
cflags=$(pkg-config --cflags sdl3 2>/dev/null || echo -I/usr/local/include)
# shellcheck disable=SC2086
if ! "$CC" -shared -fPIC $cflags -o "$TMP/shim.so" "$ROOT/tests/wm/cursorshim.c" -ldl 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "SKIP: the cursor shim does not compile here"
	exit 77
fi

LOG=$TMP/log
cd "$ROOT"
SDL_VIDEODRIVER=dummy LD_PRELOAD="$TMP/shim.so" with_timeout 90 "$EMU" -c1 -pheap=512m -pimage=512m -g1000x800 -r"$ROOT" \
	/dis/sh.dis -c "wm/wm sh /tests/wm/cursor.sh" </dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

# the cursor calls step $1 made: those since the step before (each
# step is marked once it is done)
calls() {
	awk -v s="$1" '/^R /{if($2 == s){printf "%s", buf; exit} buf = ""; next} /^C /{sub(/^C /, ""); buf = buf $0 "\n"}' "$LOG"
}
# step, then the cursor it must leave: "default", or a mask's bit count
expect() {
	step=$1 want=$2
	if ! grep -q "^R $step\$" "$LOG"; then
		fail "$step: never reached"
		return
	fi
	got=$(calls "$step")
	if printf '%s\n' "$got" | grep -q ' other$'; then
		fail "$step: a cursor call made off the main thread: $(echo $got)"
		return
	fi
	# the last cursor made, or the default when the last call destroys it
	last=$(printf '%s\n' "$got" | awk '/^create/{c = $2} /^destroy/{c = "default"} END{print c}')
	if [ "$want" = default ]; then
		[ "$last" = default ] && echo "PASS: $step (the arrow)" ||
			fail "$step: cursor '$last', want the default arrow (calls: $(echo $got))"
	else
		[ "$last" = "$want" ] && printf '%s\n' "$got" | grep -q '^set ' && echo "PASS: $step ($3)" ||
			fail "$step: cursor '$last', want $3, $want mask bits (calls: $(echo $got))"
	fi
}

# rio's cross has 112 bits in its mask, its gunsight 207
expect new 112 "the cross"
expect swept default
expect delete 207 "the gunsight"
expect cancelled default
# a move written to /dev/pointer warps the host's pointer, on the main
# thread: emu warped it on the thread that wrote, as it did the cursor
if ! grep -q '^R warp$' "$LOG"; then
	fail "warp: never reached"
else
	got=$(calls warp)
	if printf '%s\n' "$got" | grep -q '^warp other$'; then
		fail "warp: the pointer warped off the main thread"
	elif printf '%s\n' "$got" | grep -q '^warp main$'; then
		echo "PASS: warp (on the main thread)"
	else
		fail "warp: the pointer never warped (calls: $(echo $got))"
	fi
fi
got=$(sed -n 's/^R windows *//p' "$LOG")
[ "$got" = "0 100 100 400 300" ] && echo "PASS: the window is where it was swept" ||
	fail "windows '$got', want '0 100 100 400 300'"

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^[RC] /!p' "$LOG" | head -20
exit 1
