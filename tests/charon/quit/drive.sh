#!/dis/sh.dis
#
# wm/charon under wm/wm on a page whose script runs a timer for ever
# (page.html), left two ways: Delete from wm's menu (wm sends it exit),
# and Ctrl-Q. For tests/host/charon_quit_test.sh (not a test: the
# runner runs every script in tests/inferno). Before and after each it
# prints R, the step and the procs of the browser and of the page's
# realm (WebBrowser, Browser, Page, Charonfs, Js): none must be left.
# The realm is a process group of its own, and a browser left either
# way left it running, its timers with it, for as long as emu ran.
#
load std

fn ptr { echo m $1 $2 $3 > /dev/pointer }
fn menu { ptr $1 $2 4; ptr $1 $3 4; ptr $1 $3 0 }
fn click { ptr $1 $2 $3; ptr $1 $2 0 }
fn code { unicode -t $1 > /dev/keyboard }
# Charon on about:blank, scripts on (they are off unless set), then the
# page: its realm only runs with them on
fn charon {
	wm/charon -g 600x400 about:blank &
	for i in 1 2 3 4 5 6 7 8 9 10 {
		if {! ftest -e '#scharon/fs'} { sleep 1 }
	}
	mkdir -p /tmp/charonquit
	mount -A '#scharon/fs' /tmp/charonquit
	echo scripts on > /tmp/charonquit/ctl
	echo open file:///tests/charon/quit/page.html > /tmp/charonquit/ctl
	unmount /tmp/charonquit
}
fn procs { echo R $1 `{ps | grep 'WebBrowser|Browser|Page|Charonfs|Js'} }

sleep 2

# Delete from wm's menu (opened on the background, right of the window)
charon
sleep 6
procs delete-before
echo R windows `{cat /chan/wmwindows}
menu 900 100 154
click 300 300 4
sleep 8	# the reaper gives a quitting realm 5 s
procs delete-after

# Ctrl-Q, the window having the keyboard
charon
sleep 6
procs ctrlq-before
click 300 300 1
code 11
sleep 8	# the reaper gives a quitting realm 5 s
procs ctrlq-after

echo R done
echo halt > '#c/sysctl'
