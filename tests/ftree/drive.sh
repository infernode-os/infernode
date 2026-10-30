#!/dis/sh.dis
#
# wm/ftree driven by keys, the pointer and its agent's ctl file
# (/tmp/veltro/ftree/ctl), on the tree in $1 (made by
# tests/host/ftree_test.sh, which checks what this prints and what it
# leaves in the tree; not a test: the runner runs every script in
# tests/inferno).  After each step it prints R, the step's name and
# ftree's state file (/tmp/veltro/ftree/state) on one line, and V and
# the step's name before its view file, a line at a time.
#
# The tree is a/ (a1.txt), b/ (b1.txt) and c.txt.  wm/wm puts the
# window at 0 0; the rows are 20 pixels apart, the tree's at y 14.
# Button 3 posts the menu with its top left at the pointer and its
# items 18 pixels apart, the first at y+10.
#
load std

d=$1
ctl=/tmp/veltro/ftree/ctl
fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn click { ptr $1 $2 0; ptr $1 $2 1; ptr $1 $2 0; sleep 1 }
fn key { unicode -t $1 > /dev/keyboard; sleep 1 }
fn show { sleep 1; echo R $1 `{cat /tmp/veltro/ftree/state}; echo V $1; cat /tmp/veltro/ftree/view }
# the menu's item at y chosen (53 the first, 71, 89, 107), button 3
# held from 100 43
fn menu { ptr 100 43 0; ptr 100 43 4; sleep 1; ptr 130 $1 4; ptr 130 $1 0; sleep 2 }
fn tell { echo $* > $ctl; sleep 2 }

mkdir -p /tmp/veltro/ftree
wm/ftree $d/tree &
sleep 5
show start

# the keys: c.txt clicked, Up to b, Right opens it
click 100 75
show clicked
key e012
show up
key e015
show right

# refresh keeps b open
echo -n r > /dev/keyboard
sleep 1
show refresh

# a bind made in ftree is in ftree's name space, not this one
tell bind $d/tree/a $d/tree/b -b
show bound
echo R parent-b `{ls $d/tree/b}
tell unmount $d/tree/b
show unmounted

# Copy c.txt, Paste into a
tell select $d/tree/c.txt
menu 71
tell select $d/tree/a
menu 89
show pasted

# Remove b, asked and answered
tell select $d/tree/b
menu 107
show asked
echo yes > /dev/keyboard
sleep 2
show removed

# -d: bind refused
kill Ftree >[2] /dev/null
sleep 1
rm -f $ctl
wm/ftree -d $d/tree &
sleep 5
tell bind $d/tree/a $d/tree/c.txt
show disallowed
echo R done
