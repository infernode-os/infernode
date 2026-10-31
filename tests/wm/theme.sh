#!/dis/sh.dis
#
# One application under wm/wm through a theme switch, for
# tests/host/wm_theme_test.sh: the application named in $app is
# started, the screen taken, the theme switched to halo, and the screen
# taken again.  The windows (a read of /chan/wmwindows) are printed as
# "R win ..." (not a test: the runner runs every script in tests/inferno).
#
load std
sleep 1
$app &
sleep 6
echo R win `{cat /chan/wmwindows}
scap /tmp/a.img
echo -n halo > /lib/lucifer/theme/current
sleep 6
scap /tmp/b.img
echo halt > '#c/sysctl'
