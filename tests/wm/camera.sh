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
