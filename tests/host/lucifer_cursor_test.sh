#!/bin/sh
#
# lucifer_cursor_test.sh — an app's cursor reaches the screen under
# Lucifer.  wm/wm asks its window server for New's cross, its box and
# Delete's gunsight with a "cursor" request; with no window server
# wmlib writes /dev/cursor itself (tests/host/wm_cursor_test.sh), but
# under Lucifer the request goes to Lucifer, which answered OK and
# dropped it: the cursor never changed.
#
# Lucifer boots under the SDL dummy driver and tests/wm/lucifercursor.sh
# makes the requests; a shim preloaded into emu (tests/wm/cursorshim.c)
# logs each cursor call, which cursor (its mask bits) and which thread.
# Linux only: it needs LD_PRELOAD.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ "$EMUHOST" = Linux ] || { echo "SKIP: the cursor shim needs LD_PRELOAD (Linux)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/lucifer.dis dis/luciuisrv.dis; do
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
SDL_VIDEODRIVER=dummy LD_PRELOAD="$TMP/shim.so" with_timeout 120 "$EMU" -c1 \
	-pheap=1024m -pmain=1024m -pimage=1024m -g1024x768 -r"$ROOT" \
	/dis/sh.dis -l -c "skiplogon=1; run /lib/lucifer/boot.sh & sleep 40; run /tests/wm/lucifercursor.sh" \
	</dev/null >"$LOG" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

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

# rio's cross has 112 bits in its mask
expect cross 112 "the cross"
expect arrow default
if grep -q '^R badrefused$' "$LOG"; then
	echo "PASS: a malformed cursor request is refused"
else
	fail "a malformed cursor request was not refused"
fi

if [ $failed = 0 ]; then echo "ALL PASS"; exit 0; fi
grep -v '^tools9p' "$LOG" | tail -20
exit 1
