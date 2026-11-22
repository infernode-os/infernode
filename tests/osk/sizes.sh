#!/dis/sh.dis
#
# wm/osk under wm/wm at the screen's size, for
# tests/host/osk_sizes_test.sh (not a test itself): its keys and status
# copied to /tmp, on each letters' layout and the symbols.
#
load std
home=/tmp/home
mkdir -p $home
wm/osk &
sleep 1
while {! grep -s '^words [1-9]' /mnt/osk/status} {sleep 1}
for l in qwerty dvorak colemak {
	echo layout $l > /mnt/osk/ctl
	sleep 1
	cat /mnt/osk/keys > /tmp/keys.$l
}
cat /mnt/osk/status > /tmp/status
cat /chan/wmwindows > /tmp/windows
echo R done
echo halt > '#c/sysctl'
