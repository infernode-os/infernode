#!/dis/sh.dis
#
# Namespace-contract test for bt9p(4): the /net/bt tree as
# docs/BLUETOOTH.md specifies it, served over btmock(4) so that it
# runs on any machine with no radio and no kernel. Asserts the files
# and their modes, the ctl verbs and their refusals, addr and status
# before and after up, a streaming scan, the event stream, and the
# exclusive hci file.
#
# Both servers are mounted under /tmp rather than /net: a test must
# not change the namespace it was started in more than it has to, and
# bt9p -m says where the tree goes.
#

load std

if {! ftest -f /dis/bt9p.dis} {
	raise 'skip:bt9p.dis not built'
}
if {! ftest -f /dis/btmock.dis} {
	raise 'skip:btmock.dis not built'
}

MNT=/tmp/btns
mkdir -p $MNT
mkdir -p $MNT/chan

HCD=/tmp/btns.hcd
btmock -a 'b8:27:eb:00:00:42' -n '94:bb:43:44:61:04 0x1c010c -61 hephaestus' -n 'aa:bb:cc:dd:ee:ff 0x000104 -80' -t 100 -H $HCD $MNT/chan/btmock &
sleep 1
if {! ftest -f $MNT/chan/btmock} {
	raise 'fail:btmock did not serve its file'
}

bt9p -t $MNT/chan/btmock -m $MNT
sleep 1
BT=$MNT/bt

# The tree.
for (f in addr status ctl scan event hci) {
	if {! ftest -f $BT/$f} {
		raise 'fail:'^$f^' missing'
	}
}
if {ftest -f $BT/clone} {
	raise 'fail:clone is served before milestone 5 -- the spec says not yet'
}

# Modes: ctl is write-only, addr and status read-only. The failing
# open must happen inside a command, not a sh redirection.
if {cat $BT/ctl > /dev/null >[2] /dev/null} {
	raise 'fail:ctl is readable (mode should be 220)'
}
if {cp /dev/null $BT/status >[2] /dev/null} {
	raise 'fail:status is writable (mode should be 444)'
}
if {cp /dev/null $BT/addr >[2] /dev/null} {
	raise 'fail:addr is writable (mode should be 444)'
}

# Before up: status says so, addr is an error rather than a guess.
v=`{cat $BT/status | grep '^up '}
if {! ~ $"v 'up 0'} {
	raise 'fail:status before up: '^$"v
}
if {cat $BT/addr > /dev/null >[2] /dev/null} {
	raise 'fail:addr readable before up'
}

# ctl refusals answer with an error, never silence.
if {echo frobnicate > $BT/ctl >[2] /dev/null} {
	raise 'fail:unknown ctl verb was accepted'
}
if {echo firmware /n/dos/firmware/no-such.hcd > $BT/ctl >[2] /dev/null} {
	raise 'fail:firmware accepted a file that does not exist'
}
if {echo baud 115200 > $BT/ctl >[2] /dev/null} {
	raise 'fail:baud accepted on a transport with no ctl file'
}
if {echo scan 0 > $BT/ctl >[2] /dev/null} {
	raise 'fail:scan 0 accepted'
}
if {echo discoverable maybe > $BT/ctl >[2] /dev/null} {
	raise 'fail:discoverable maybe accepted'
}

# up: reset the controller and learn who it is.
echo up > $BT/ctl
v=`{cat $BT/addr}
if {! ~ $"v 'b8:27:eb:00:00:42'} {
	raise 'fail:addr after up: '^$"v
}
v=`{cat $BT/status | grep '^up '}
if {! ~ $"v 'up 1'} {
	raise 'fail:status after up: '^$"v
}
v=`{cat $BT/status | grep '^hci '}
if {! ~ $"v 'hci 4.2 lmp 4.2 manufacturer 15 (Broadcom)'} {
	raise 'fail:version line: '^$"v
}
v=`{cat $BT/status | grep '^name '}
if {! ~ $"v 'name btmock'} {
	raise 'fail:name from the controller: '^$"v
}

# The settable things, and that status reflects them.
echo name infer node > $BT/ctl
echo class 0x1c0104 > $BT/ctl
echo discoverable on > $BT/ctl
v=`{cat $BT/status | grep '^name '}
if {! ~ $"v 'name infer node'} {
	raise 'fail:name after write: '^$"v
}
v=`{cat $BT/status | grep '^class '}
if {! ~ $"v 'class 0x1c0104'} {
	raise 'fail:class after write: '^$"v
}
v=`{cat $BT/status | grep '^discoverable '}
if {! ~ $"v 'discoverable 1'} {
	raise 'fail:discoverable after write: '^$"v
}

# A scan: one line per device as found, EOF at Inquiry Complete. Two
# devices were given to the mock; both come back with class and RSSI.
echo scan 1 > $BT/ctl
scan=`{cat $BT/scan}
n=`{cat $BT/scan | wc -l}
if {! ~ $"n 2} {
	raise 'fail:scan returned '^$"n^' lines, wanted 2'
}
if {! ~ $"scan *94:bb:43:44:61:04*0x1c010c*-61*} {
	raise 'fail:scan is missing the first device: '^$"scan
}
if {! ~ $"scan *aa:bb:cc:dd:ee:ff*0x000104*-80*} {
	raise 'fail:scan is missing the second device: '^$"scan
}
v=`{cat $BT/status | grep '^scans '}
if {! ~ $"v 'scans 2'} {
	raise 'fail:scans counted: '^$"v
}

# The event stream: a reader parked on it sees the inquiry's events go
# by. Its output goes beside the mount, not under it: a mount without
# MCREATE forbids creation, which is right for /net/bt.
EV=/tmp/btns-events
read 4000 < $BT/event > $EV &
sleep 1
cat $BT/scan > /dev/null
sleep 1
ev=`{cat $EV}
rm -f $EV
if {! ~ $"ev *'event 0x22'*} {
	raise 'fail:event stream did not show an Inquiry Result: '^$"ev
}

# hci is exclusive, and holding it lends the controller away.
sleep 3 <> $BT/hci &
sleep 1
if {cat $BT/hci > /dev/null >[2] /dev/null} {
	raise 'fail:hci opened twice'
}
if {echo reset > $BT/ctl >[2] /dev/null} {
	raise 'fail:ctl talked to the controller while hci was held'
}
sleep 3
echo reset > $BT/ctl
v=`{cat $BT/status | grep '^up '}
if {! ~ $"v 'up 0'} {
	raise 'fail:status after reset: '^$"v
}

# The patch upload: name the file, and the next up sends its records
# -- Download_Minidriver, each record, Launch_RAM -- then resets and
# asks again. Status says how many went.
echo firmware $HCD > $BT/ctl
v=`{cat $BT/status | grep '^firmware '}
if {! ~ $"v 'firmware '^$HCD^' (not uploaded yet)'} {
	raise 'fail:firmware named but status says: '^$"v
}
echo up > $BT/ctl
v=`{cat $BT/status | grep '^firmware '}
if {! ~ $"v 'firmware '^$HCD^' (uploaded 3 records)'} {
	raise 'fail:after up with firmware, status says: '^$"v
}
v=`{cat $BT/addr}
if {! ~ $"v 'b8:27:eb:00:00:42'} {
	raise 'fail:addr after patched up: '^$"v
}
rm -f $HCD

echo PASS
