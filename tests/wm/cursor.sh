#!/dis/sh.dis
#
# wm/wm's cursors, driven by the pointer (/chan/uitest): New's cross,
# the arrow again once swept, the gunsight Delete asks with, the arrow
# again when it is cancelled.  After each step it prints R and the
# step's name; tests/host/wm_cursor_test.sh checks the cursor changes
# emu made through SDL between them (not a test: the runner runs every
# script in tests/inferno).
#
load std

fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
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

echo R windows `{cat /chan/uitest} >[1=2]
echo R done >[1=2]
echo halt > '#c/sysctl'
