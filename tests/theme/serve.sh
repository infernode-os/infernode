#!/dis/sh.dis
#
# themefs and lucitheme's watch, for tests/host/themefs_test.sh (not a
# test: the runner runs every script in tests/inferno).  $1 is a theme
# directory of the test's own, bound over /lib/lucifer/theme; what each
# step gives is written beside it.
#
load std

d=$1
bind -bc $d /lib/lucifer/theme
themefs
ls /lib/lucifer/theme > $d/ls
cat /lib/lucifer/theme/current > $d/cur.before
cat /lib/lucifer/theme/event > $d/events &
sleep 1
echo -n halo > /lib/lucifer/theme/current
cat /lib/lucifer/theme/current > $d/cur.after
# a name that is no theme: refused, in a shell of its own (a write
# refused ends the shell it is in)
sh -c 'echo -n nosuch > /lib/lucifer/theme/current' >[2] $d/err
themefs >[2] $d/again
echo brimstone > /lib/lucifer/theme/current
sleep 1
echo R done
echo halt > '#c/sysctl'
