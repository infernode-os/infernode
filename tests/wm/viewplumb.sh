#!/dis/sh.dis
#
# wm/view under wm/wm with the Desktop's plumbing rules: an image
# plumbed, its window deleted, three times.  Each must start a view
# with a window: view told the plumber "start" for its port and never
# "stop", so after the first was deleted the rest went to a port
# nobody read.  tests/host/wm_view_plumb_test.sh reads the R lines
# (not a test: the runner runs every script in tests/inferno).
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }
fn show { sleep 3; echo R $1 `{cat /chan/wmwindows} }

bind -bc '#splumber' /chan
/lib/sh/plumbrules start /lib/wm/plumbing
sleep 2
show start
for i in 1 2 3 {
	plumb /tests/imgload/rb.jpg
	show open$i
	# Delete from wm/wm's menu, then a click inside the window
	# (rb.jpg is 16x16)
	(nil x0 y0 nil nil) = `{sed 1q /chan/wmwindows}
	if {~ $#x0 1} {
		x = `{echo $x0 + 8 | calc}
		y = `{echo $y0 + 8 | calc}
		menu 900 100 154
		click $x $y 4
	}
	show deleted$i
}
echo R done
