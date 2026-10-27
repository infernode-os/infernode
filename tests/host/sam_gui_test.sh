#!/bin/sh
#
# wm/sam end to end through the GUI: boot a headless wm/wm, start sam
# on a file, and drive it with synthetic input through /dev/pointer and
# /dev/keyboard — open a window on the file from menu 3, type a command
# in the command window, double-click words in the file window, change
# them, write.  Checks the file sam wrote, not pixels.
#
# Covers what the protocol-level tests/sam_test.b cannot: that samterm
# pumps keyboard and mouse into Tk, that command output leaves the
# command window's typing point at its end, that a double click reaches
# the engine, and that host changes redraw the window.
#
# Needs a built emu and dis/ (mk install in appl); skips without them.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/wm/sam.dis" ] && [ -f "$ROOT/dis/wm/wm.dis" ] || {
    echo "SKIP: dis/wm not built"; exit 77; }

T=tmp/samgui_test.$$
DIR="$ROOT/$T"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

printf 'The quick brown fox\njumps over\nthe lazy dog.\n' > "$DIR/fox.txt"

# As in Plan 9, sam starts with the command window alone, across the
# top fifth of its 640x480 window (y 5 to 100); the file is listed in
# menu 3, the newest entry, which the menu posts under the pointer.
# Releasing button 3 there picks it, and a click of button 3, not a
# sweep, gives the new window the space below the command window: its
# first line is at y=111, "quick" at x=70, its third at y=143, "lazy"
# at x=60.  Button 1 in a window that is not current only makes it
# current.  "lazy" is double-clicked as SDL reports one, two plain
# clicks, which samterm times as Plan 9's does; "quick" with the
# second press marked by button bit 8 (257), as X11 reports one.
cat > "$DIR/drive.sh" <<EOF
load std
wm/wm wm/sam /$T/fox.txt &
sleep 5
fn click { echo m \$1 \$2 1 > /dev/pointer; echo m \$1 \$2 0 > /dev/pointer }
echo m 300 300 4 > /dev/pointer
sleep 1
echo m 300 300 0 > /dev/pointer
sleep 1
echo m 300 300 4 > /dev/pointer; echo m 300 300 0 > /dev/pointer
sleep 1
click 300 50
sleep 1
echo ',s/o/0/g' > /dev/keyboard
sleep 1
click 60 143
sleep 1
click 60 143; click 60 143
sleep 1
click 300 50
sleep 1
echo 'c/sleepy/' > /dev/keyboard
sleep 1
click 70 111
sleep 1
click 70 111; echo m 70 111 257 > /dev/pointer; echo m 70 111 0 > /dev/pointer
sleep 1
click 300 50
sleep 1
echo 'c/slow/' > /dev/keyboard
sleep 1
echo w > /dev/keyboard
sleep 2
echo R_DONE
EOF

LOG="$DIR/log"
(cd "$DIR" && SDL_VIDEODRIVER=dummy exec "$EMU" -c1 -pheap=512m -pmain=512m -pimage=512m \
    -g1024x768 -r"$ROOT" /dis/sh.dis "/$T/drive.sh" </dev/null >"$LOG" 2>&1) &
PID=$!
i=0
while [ $i -lt 60 ] && ! grep -q R_DONE "$LOG" 2>/dev/null; do
    sleep 1
    i=$((i+1))
done
kill $PID 2>/dev/null
wait $PID 2>/dev/null

if ! grep -q R_DONE "$LOG"; then
    echo "FAIL: driver did not finish"
    cat "$LOG"
    exit 1
fi

want='The slow br0wn f0x
jumps 0ver
the sleepy d0g.'
got=$(cat "$DIR/fox.txt")
if [ "$got" != "$want" ]; then
    echo "FAIL: file after editing through the GUI"
    echo "--- want"; echo "$want"
    echo "--- got"; echo "$got"
    echo "--- emu log"; cat "$LOG"
    exit 1
fi
echo "PASS: sam edits through the GUI"
exit 0
