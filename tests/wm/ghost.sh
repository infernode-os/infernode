#!/dis/sh.dis
#
# A wm/wm client that leaves: where its window was must be wm's
# background again, not the client's own screen fill (INFR-433).
# tests/host/wm_ghost_test.sh reads the screenshots (not a test: the
# runner runs every script in tests/inferno).
#
load std

fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
fn show { sleep 2; echo R $1 `{cat /chan/uitest} }
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

echo R done
echo halt > '#c/sysctl'
