#!/dis/sh.dis
#
# wm/wm's cursors, driven by the pointer (/dev/pointer): New's cross,
# the arrow again once swept, the gunsight Delete asks with, the arrow
# again when it is cancelled; then the pointer warped by a move written
# to /dev/pointer.  After each step it prints R and the step's name;
# tests/host/wm_cursor_test.sh checks the cursor changes and warps emu
# made through SDL between them (not a test: the runner runs every
# script in tests/inferno).
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn mark { sleep 1; echo R $1 >[1=2] }
# button 3 pressed at x y, moved to y2, released: the item there
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }

sleep 2
mark start

# New, chosen by a click that never moves, as a trackpad sends it
ptr 500 400 4
ptr 500 400 0
mark new

# the sweep, from where it is pressed
ptr 100 100 4
ptr 250 200 4
ptr 400 300 4
ptr 400 300 0
mark swept

# Delete: the gunsight, then button 1, which cancels it
menu 900 100 154
mark delete
ptr 600 600 1
ptr 600 600 0
mark cancelled

# the pointer moved there, as wmlib's "ptr" request moves it: a write
# with no buttons warps the host's pointer
echo m 300 300 > /dev/pointer
mark warp

echo R windows `{cat /chan/wmwindows} >[1=2]
echo R done >[1=2]
echo halt > '#c/sysctl'
