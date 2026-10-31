#!/dis/sh.dis
#
# wm/road under wm/wm, for tests/host/road_test.sh (not a test: the
# runner runs every script in tests/inferno).  $1 is the test's
# directory, holding map.txt and the themes; the emulator is started
# with $INFERNODE_LOCATION_FAKE, so #g gives a fix a second, read by
# gpsfs.  What each step gives is written beside it: the screen while
# following, after the view is moved by its ctl, and after a theme
# switch; the files' contents; the errors refused writes got.  A write
# refused ends the shell it is in, so each that may be is made in a
# shell of its own.
#
load std

d=$1
sleep 1
gpsfs source '#g/nmea'
wm/road -w 1500 $d/map.txt &
sleep 8
echo R win `{cat /chan/wmwindows}
scap $d/a.img

# a ship by AIS, 311 m north and 231 m east of the fix
echo '!AIVDM,1,1,,A,B7Odch@0<Re3KFK:3c0p@e000000,0*72' > /mnt/gps/feed
sleep 4
scap $d/d.img

mkdir -p /mnt/road
mount -A '#sroad/fs' /mnt/road
ls /mnt/road > $d/ls
cat /mnt/road/event > $d/events &
sleep 1
cat /mnt/road/view > $d/view.a
cat /mnt/road/marks > $d/marks.a

for c in 'center 99 0' 'width 5' 'bogus' 'unmark nosuch' 'follow sideways' 'units furlongs' {
	sh -c 'echo '^$"c^' > /mnt/road/ctl' >[2] $d/err.^`{echo $c | sed 's/ .*//'}
}

echo center -33.8600 151.2100 > /mnt/road/ctl
cat /mnt/road/view > $d/view.b
sleep 3
scap $d/b.img

echo mark -33.8570 151.2150 X > /mnt/road/ctl
cat /mnt/road/marks > $d/marks.b
echo unmark X > /mnt/road/ctl
cat /mnt/road/marks > $d/marks.c
echo follow on > /mnt/road/ctl
echo units nautical > /mnt/road/ctl
cat /mnt/road/view > $d/view.c

echo -n halo > /lib/lucifer/theme/current
sleep 4
scap $d/c.img
echo R done
echo halt > '#c/sysctl'
