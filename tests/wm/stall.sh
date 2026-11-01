#!/dis/sh.dis
#
# wm/settings with a service that never answers, for
# tests/host/settings_stall_test.sh (not a test: the runner runs every
# script in tests/inferno): its window comes up all the same, its list
# answers a click, and it deletes itself from its own loop.
#
load std file2chan

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }

sleep 2
file2chan /chan/hang {rblock} {}
echo x > /tmp/models
bind /tmp /mnt/llm
bind /chan/hang /mnt/llm/models
wm/settings &
sleep 6
echo R open `{cat /chan/wmwindows}
ps | grep Settings | grep -v 'release|Sh' > /tmp/alive
echo R alive `{cat /tmp/alive}
scap /tmp/stall-0.img
# the window's own Exit path, not wm's fallback: wm/settings takes it in
# its loop, so nothing of it is left
menu 900 700 754
click 100 100 4
sleep 1
echo R deleted `{cat /chan/wmwindows}
echo R left `{ps | grep Settings}
echo R done
echo halt > '#c/sysctl'
