#!/dis/sh.dis
#
# A wm/wm client that leaves: where its window was must be wm's
# background again, not the client's own screen fill (INFR-433).
# tests/host/wm_ghost_test.sh reads the screenshots (not a test: the
# runner runs every script in tests/inferno).
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn show { sleep 2; echo R $1 `{cat /chan/wmwindows} }
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }

sleep 2
show start

# a client deleted from the menu: wm sends it exit
wm/colors &
sleep 3
show colors
scap /tmp/ghost-0.img
menu 900 100 154
click 100 100 4
show deleted
sleep 1
scap /tmp/ghost-1.img

# a client that exits by itself: its process killed
wm/colors &
sleep 3
show colors2
kill -g Colors
show killed
sleep 1
scap /tmp/ghost-2.img

# a client that has stopped: it never takes the exit, and its window
# still goes, a moment after
/dis/tests/wm_frozen.dis &
sleep 2
show frozen
scap /tmp/ghost-3.img
menu 900 100 154
click 100 100 4
sleep 3
show frozen-deleted
scap /tmp/ghost-4.img
# wm still works: a window after it
wm/colors &
sleep 3
show after-frozen
menu 900 100 154
click 100 100 4
show after-frozen-deleted

# programs that once shared wm's process group: an exit is a killgrp
wm/dir &
sleep 3
show dir
menu 900 100 154
click 100 100 4
show dir-deleted
wm/task &
sleep 3
show task
menu 900 100 154
click 100 100 4
show task-deleted

# Matrix hosting a program in a group of its own: both go, or the
# hosted one keeps the window with nothing left to take a Delete
wm/matrix /lib/matrix/compositions/scene-demo &
sleep 4
show matrix
menu 900 100 154
click 100 100 4
sleep 3
show matrix-deleted
echo R matrix-left `{ps | grep 'WmScene|Matrix|SceneFixture'}

# a client that took the exit and stays is asking its user: it stays
/dis/tests/wm_frozen.dis -k &
sleep 2
menu 900 100 154
click 100 100 4
sleep 3
show keeps
echo R done
echo halt > '#c/sysctl'
