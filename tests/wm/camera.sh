#!/dis/sh.dis
#
# wm/camera lets go of the feed while hidden (wm/wm's Hide sends it
# "visible 0") and takes it back when shown: the camera is off with no
# one looking. Over camsrv -t, so no camera is needed.
# tests/host/wm_camera_test.sh reads the R lines.
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }
fn status { echo R $1 `{cat /mnt/video/0/status} }

mount -ac {mntgen} /mnt
mount -A {camsrv -t} /mnt/video
# snapshots go to $home/camera
home=/tmp/home
mkdir -p $home
wm/camera &
sleep 4
echo R windows `{cat /chan/wmwindows}
status shown
# Hide (the fifth item of wm's menu), then the camera's window
menu 900 100 172
click 150 120 4
sleep 3
status hidden
# turned while let go: shown again, the window takes the turned size
echo rotate 90 > /mnt/video/0/ctl
# the hidden window is the menu's sixth item
menu 900 100 190
sleep 3
status unhidden
echo R turned `{cat /chan/wmwindows}
# turned back while shown: the camera says so at the next frame
# ("format changed") and the window follows, streaming throughout
echo rotate 0 > /mnt/video/0/ctl
sleep 3
status live
echo R live `{cat /chan/wmwindows}
# The camera's own menu, button 3 in its window. menuhit keeps a menu
# inside the window and puts the item chosen last under the pointer: a
# press near the window's top (its border is 4) puts the menu against
# that top whatever was chosen last, each item 18 pixels below the last,
# the first at y 17.
fn pick { menu 120 17 $1 }
# snapshot
pick 17
sleep 2
echo R snap `{ls $home/camera}
# mirror
pick 71
sleep 2
echo R mirrored `{cat /mnt/video/0/ctl}
# upside down
pick 53
sleep 2
echo R upside `{cat /mnt/video/0/ctl}
# rotate 90: from 180 to 270, and the window turns
pick 35
sleep 3
echo R rotated `{cat /mnt/video/0/ctl}
echo R rotwin `{cat /chan/wmwindows}
# exit
pick 89
sleep 2
echo R exited `{cat /chan/wmwindows}
echo R done
