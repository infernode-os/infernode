#!/dis/sh.dis
#
# wm/wm as an app in Lucifer's presentation zone, its cursors driven by
# the pointer (/dev/pointer): New's cross, the arrow once swept, the
# gunsight Delete asks with, the arrow when the pointer leaves the zone
# and the gunsight when it comes back, the arrow when Delete is
# cancelled.  After each step it prints R and the step's name;
# tests/host/lucifer_cursor_test.sh checks the cursor changes emu made
# through SDL between them (not a test: the runner runs every script in
# tests/inferno).  Points are in the zone at 1280x800.
#
load std

ui=/mnt/ui/activity/0/presentation
fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn mark { sleep 2; echo R $1 > '#c/cons' }

echo 'create id=wm type=app label=wm dis=/dis/wm/wm.dis' > $ui/ctl
echo 'center id=wm' > $ui/ctl
sleep 6
echo R status `{cat $ui/wm/appstatus} > '#c/cons'
ptr 670 400 0
mark start

# New, chosen by a click that never moves
ptr 670 400 4
ptr 670 400 0
mark new

# the sweep
ptr 600 300 4
ptr 700 400 4
ptr 800 500 4
ptr 800 500 0
mark swept

# Delete, from the menu opened above the new window (New, the last
# chosen, under the pointer; Delete below it)
ptr 700 250 0
ptr 700 250 4
ptr 700 304 4
ptr 700 304 0
mark delete

# out of the zone, into the conversation, and back
ptr 100 400 0
mark left
ptr 700 450 0
mark back

# button 1 cancels Delete
ptr 700 450 1
ptr 700 450 0
mark cancelled

echo R done > '#c/cons'
echo halt > '#c/sysctl'
