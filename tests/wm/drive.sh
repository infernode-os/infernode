#!/dis/sh.dis
#
# wm/wm driven by the pointer (/chan/uitest): rio's button-3 menu (New,
# Resize, Move, Delete, Hide and the hidden windows), the frame's move
# and reshape, click to focus, and the background.  After each step it
# prints R, the step's name and the windows (a read of /chan/uitest:
# id minx miny maxx maxy, topmost first); tests/host/wm_test.sh checks
# them (not a test: the runner runs every script in tests/inferno).
#
# The menu opens with New under the pointer and its items are 18 pixels
# apart (the menu font's 16, and 2 between): from a press at y, Resize
# is at y+18, Move y+36, Delete y+54, Hide y+72, the first hidden window
# y+90.  Events follow each other with no motion between, as a trackpad
# sends them.
#
load std

fn ptr { echo ptr $1 $2 $3 > /chan/uitest }
fn show { sleep 2; echo R $1 `{cat /chan/uitest} }
# button 3 pressed at x y, moved to y2, released: the item there
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
# a click of buttons b at x y
fn click { ptr $1 $2 $3; ptr $1 $2 0 }
# a drag of buttons b from x y to x2 y2
fn drag { ptr $2 $3 $1; ptr $4 $5 $1; ptr $4 $5 0 }

sleep 2
show start

# New, chosen by a click that never moves (New is under the pointer),
# then swept at once: the window is where it was swept
click 500 400 4
drag 4 100 100 400 300
show new-click

# New, held and moved a little within it, then swept
menu 700 600 601
ptr 450 350 0
drag 4 450 350 800 650
show new-held

# New, then button 1 instead of the sweep: no window
click 900 50 4
drag 1 600 60 700 100
show new-cancel

# New, then a sweep too small for a window: none
click 900 50 4
drag 4 600 60 640 80
show new-small

# button 1 and 2 on the background do nothing
click 900 750 1
click 900 750 2
show background

# button 1 in a window that is not current makes it current, on top
click 200 200 1
show focus

# button 3 on a window's frame moves it; button 1 on its edge reshapes
# from that edge alone
drag 4 250 101 300 151
show frame-move
drag 1 448 250 498 250
show frame-reshape

# Move: the gunsight, then button 3 drags the window chosen
menu 900 100 136
drag 4 600 500 650 450
show menu-move

# Resize: choose the window, then sweep its new rectangle
menu 900 100 118
click 300 200 4
drag 4 100 450 400 700
show menu-resize

# Hide: chosen, it leaves the screen; chosen on the menu, it is back
menu 900 100 172
click 600 400 4
show menu-hide
menu 900 100 190
show menu-unhide

# Delete: the window chosen goes
menu 900 100 154
click 200 600 4
show menu-delete

# a click that never moves, then a button that cancels the gunsight
menu 900 100 154
click 600 400 1
show delete-cancel

# a theme switched (as Xenith's Theme does): the windows' frames and
# the menu follow.  The host gives /lib/lucifer/theme as a copy.
scap /tmp/wm-theme-0.img
echo -n halo > /lib/lucifer/theme/current
sleep 3
scap /tmp/wm-theme-1.img
ptr 900 100 4
sleep 1
scap /tmp/wm-theme-menu.img
ptr 990 790 4
ptr 990 790 0
show theme

echo R done
echo halt > '#c/sysctl'
