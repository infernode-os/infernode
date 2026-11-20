#!/dis/sh.dis
#
# wm/settings's Edit buttons on the Desktop, for
# tests/host/settings_edit_test.sh (not a test: the runner runs every
# script in tests/inferno): the plumber started as lib/wm/desktop.sh
# starts it, no Lucifer (/mnt/ui) anywhere, and "Edit current theme"
# clicked.  The file must open in Xenith through the plumber.
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }

/lib/sh/plumbrules start /lib/wm/plumbing
sleep 2
wm/settings -c theme &
sleep 5
echo R before `{cat /chan/wmwindows}
# the Theme panel's "Edit current theme" button, at -g1000x800
click 270 182 1
sleep 6
echo R after `{cat /chan/wmwindows}
echo R xenith `{ps | grep Xenith}
echo R done
echo halt > '#c/sysctl'
