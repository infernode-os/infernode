#!/dis/sh.dis
#
# wm/edit driven by the pointer and keys (/dev/pointer, /dev/keyboard),
# on files in $1 (made by tests/host/wm_edit_test.sh, which checks what
# this prints and what it writes; not a test: the runner runs every
# script in tests/inferno).  After each step it prints R, the step's name
# and the windows wm/wm lists (/chan/wmwindows: id minx miny maxx maxy,
# topmost first).
#
# wm/wm puts the first window at 0 0.  The File menu posts from its
# button at 20 12; its items are New at y 32, Open... 50, Save 74,
# Save As... 92 and Exit 116, at x 25.
#
load std

d=$1
fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn click { ptr $1 $2 1; ptr $1 $2 0; sleep 1 }
fn file { click 20 12; click 25 $1 }
fn show { sleep 2; echo R $1 `{cat /chan/wmwindows} }
New=32; Save=74; Exit=116

# read with the arrow and page keys, then Exit: nothing changed, so it
# leaves without asking
wm/edit $d/read.txt &
sleep 4
show open
scap $d/open.img
for k in e013 e013 e015 e017 e012 e010 {
	unicode -t $k > /dev/keyboard
}
sleep 1
file $Exit
show read-exit

# typed into at the end and saved, then Exit: saved, so it leaves
wm/edit $d/save.txt &
sleep 4
click 300 300
echo -n 'added' > /dev/keyboard
sleep 1
file $Save
show saved
file $Exit
show saved-exit

# a name that does not exist yet: a new file, written by Save
wm/edit $d/new.txt &
sleep 4
click 300 300
echo -n 'brand new' > /dev/keyboard
sleep 1
file $Save
file $Exit
show new-exit

# typed into and not saved: Exit asks (a dialog over the editor), and
# the window stays
wm/edit $d/read.txt &
sleep 4
click 300 300
echo -n 'unsaved' > /dev/keyboard
sleep 1
file $Exit
show dirty-exit
echo R done
