#!/bin/sh
#
# lucifer_cursor_test.sh — an app's cursors in Lucifer's presentation
# zone reach the screen.  wm/wm run there asks for its cross, gunsight
# and box as it does at the top (wmlib's "cursor" request), but to
# Lucifer's window server, which answered OK and did nothing: under
# Lucia wm/wm's New and Delete showed only the arrow.  Lucifer now shows
# the cursor of the window the pointer goes to, and the arrow once the
# pointer leaves the zone.
#
# Lucifer boots under the SDL dummy driver and tests/wm/zonecursor.sh
# opens wm/wm in the zone and drives it; the shim of wm_cursor_test.sh
# (tests/wm/cursorshim.c), preloaded into emu, logs each cursor call,
# which cursor (its mask bits) and which thread.
# Linux only: it needs LD_PRELOAD.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ "$EMUHOST" = Linux ] || { echo "SKIP: the cursor shim needs LD_PRELOAD (Linux)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/wm/wm.dis dis/wm/sh.dis dis/lib/menuhit.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
syms=$(nm "$EMU" 2>/dev/null || true)
if [ -n "$syms" ] && ! printf '%s\n' "$syms" | grep -q sdl3_mainloop; then
	echo "SKIP: $EMU is a headless build and has no display"
	exit 77
fi

# a home of its own (the theme and what boot keeps go there)
H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
CC=$(command -v cc || command -v gcc || command -v clang || true)
[ -n "$CC" ] || { echo "SKIP: no C compiler for the shim"; exit 77; }
cflags=$(pkg-config --cflags sdl3 2>/dev/null || echo -I/usr/local/include)
# shellcheck disable=SC2086
if ! "$CC" -shared -fPIC $cflags -o "$H/shim.so" "$ROOT/tests/wm/cursorshim.c" -ldl 2>"$H/cc.log"; then
	cat "$H/cc.log"
	echo "SKIP: the cursor shim does not compile here"
	exit 77
fi

LOG=$H/log
cd "$ROOT"
SDL_VIDEODRIVER=dummy HOME=$H LD_PRELOAD="$H/shim.so" with_timeout 200 "$EMU" -c1 -pheap=1024m -pmain=1024m -pimage=1024m -g1280x800 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 45; run /tests/wm/zonecursor.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

grep -q '^R done$' "$LOG" || { echo "FAIL: the driver did not finish"; tail -20 "$LOG"; exit 1; }
grep -q '^R status running$' "$LOG" || fail "wm/wm is not running in the zone: $(grep '^R status' "$LOG")"

# the cursor calls step $1 made: those since the step before
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
expect left default
expect back 207 "the gunsight again"
expect cancelled default

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
sed -n '/^[RC] /!p' "$LOG" | tail -20
exit 1
