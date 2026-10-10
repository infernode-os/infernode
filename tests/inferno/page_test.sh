#!/dis/sh.dis
#
# wm/page driven by keys (/chan/uitest, under wm/wm): the page shown
# written as an image (W) on page 1, on page 2 (n), and turned right (r);
# tests/host/page_test.sh checks the images.
#
load std

fn key { for c in $* { echo key $c > /chan/uitest; sleep 1 } }
# W, a file name, Enter: /tmp/page-N.bit
fn write { key 87 47 116 109 112 47 112 97 103 101 45 $1 46 98 105 116 10; sleep 2 }

wm/page /tests/page/three.pdf &
sleep 6
write 49		# 1
key 110			# n
sleep 2
write 50		# 2
key 114			# r
sleep 3
write 114		# r
echo halt > '#c/sysctl'
