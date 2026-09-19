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
KEYS=/tmp/btns-keys
rm -f $KEYS
# a keys file from before the one-key-per-peer rule: the same peer three
# times, the last line the current key. Loading keeps one and rewrites.
echo 'key proto=btlink addr=99:99:99:99:99:99 type=4 !key=00000000000000000000000000000001' > $KEYS
echo 'key proto=btlink addr=99:99:99:99:99:99 type=4 !key=00000000000000000000000000000002' >> $KEYS
echo 'key proto=btlink addr=98:98:98:98:98:98 type=4 !key=00000000000000000000000000000009' >> $KEYS
echo 'key proto=btlink addr=99:99:99:99:99:99 type=4 !key=00000000000000000000000000000003' >> $KEYS
btmock -a 'b8:27:eb:00:00:42' -n '94:bb:43:44:61:04 0x1c010c -61 hephaestus' -n 'aa:bb:cc:dd:ee:ff 0x000104 -80' -n 'aa:aa:aa:aa:aa:01 0x000540 -50 oldkbd pin=1234' -n 'bb:bb:bb:bb:bb:02 0x000540 -50 sspdev ssp' -n 'cc:cc:cc:cc:cc:03 0x000540 -50 sspdev2 ssp' -n 'dd:dd:dd:dd:dd:04 0x000540 -50 caller ssp' -n 'ee:ee:ee:ee:ee:05 0x000000 -55 mockmouse le' -n 'ee:ee:ee:ee:ee:06 0x000000 -60 modernmouse lereport' -n 'ee:ee:ee:ee:ee:07 0x000000 -58 scphone lesc' -t 100 -H $HCD $MNT/chan/btmock &
sleep 1
if {! ftest -f $MNT/chan/btmock} {
	raise 'fail:btmock did not serve its file'
}

# factotum, for the pairing keys: the one already running if there is
# one, else our own at a mount point of our own.
FACT=/mnt/factotum
if {! ftest -f $FACT/ctl} {
	if {! ftest -f /dis/auth/factotum.dis} {
		raise 'skip:no factotum'
	}
	FACT=$MNT/factotum
	mkdir -p $FACT
	auth/factotum -m $FACT
	sleep 1
}
if {! ftest -f $FACT/ctl} {
	raise 'fail:factotum did not start'
}

# An audit sink, so that what bt9p records can be checked: a plain
# file where auditfs would be, holding the last record written at its
# start (the module opens and writes at offset 0; auditfs appends and
# seals), so a check is a prefix match.
AUDIT=$MNT/audit
mkdir -p $AUDIT
echo -n > $AUDIT/log
if {! ftest -d /mnt/audit} {
	mkdir -p /mnt/audit
}
bind $AUDIT /mnt/audit
bt9p -t $MNT/chan/btmock -m $MNT -f $FACT -k $KEYS
sleep 1
BT=$MNT/bt

# The tree.
for (f in addr status ctl scan lescan event hci pair) {
	if {! ftest -f $BT/$f} {
		raise 'fail:'^$f^' missing'
	}
}
if {! ftest -f $BT/clone} {
	raise 'fail:clone missing'
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
v=`{grep '99:99:99:99:99:99' $KEYS | wc -l}
if {! ~ $"v 1} {
	raise 'fail:superseded keys were not dropped from the keys file: '^$"v^' lines'
}
v=`{grep '99:99:99:99:99:99' $KEYS}
if {! ~ $"v *0000003} {
	raise 'fail:the wrong key survived the rewrite: '^$"v
}
v=`{grep '98:98:98:98:98:98' $KEYS | wc -l}
if {! ~ $"v 1} {
	raise 'fail:an unrelated key was lost in the rewrite'
}
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

# bdaddr: the vendor write, then what the controller reports is what
# addr says. A malformed address is refused before anything is sent.
if {echo bdaddr not-an-address > $BT/ctl >[2] /dev/null} {
	raise 'fail:bdaddr took a malformed address'
}
echo bdaddr b8:27:eb:ca:4c:8e > $BT/ctl
v=`{cat $BT/addr}
if {! ~ $"v 'b8:27:eb:ca:4c:8e'} {
	raise 'fail:addr after bdaddr: '^$"v
}
echo bdaddr b8:27:eb:00:00:42 > $BT/ctl	# back to the mock's own; it keeps what it is told

# A scan: one line per device, written once its name is known -- a
# Remote Name Request after the inquiry -- EOF after the last. Two
# devices were given to the mock, one with a name; the other's name
# request is a page timeout, and it goes out as "-".
echo scan 1 > $BT/ctl
scan=`{cat $BT/scan}
n=`{cat $BT/scan | wc -l}
if {! ~ $"n 6} {
	raise 'fail:scan returned '^$"n^' lines, wanted 6 (every device given to the mock)'
}
if {! ~ $"scan *94:bb:43:44:61:04*0x1c010c*-61*hephaestus*} {
	raise 'fail:scan is missing the first device or its name: '^$"scan
}
if {! ~ $"scan *aa:bb:cc:dd:ee:ff*0x000104*-80*-*} {
	raise 'fail:scan is missing the nameless second device: '^$"scan
}

# An LE scan: one line per device heard, address type, RSSI, the
# name from its advertising data; EOF when the scan time is up.
le=`{cat $BT/lescan}
n=`{cat $BT/lescan | wc -l}
if {! ~ $"n 9} {
	raise 'fail:lescan returned '^$"n^' lines, wanted 9 (every device given to the mock advertises)'
}
if {! ~ $"le *94:bb:43:44:61:04*public*-61*hephaestus*} {
	raise 'fail:lescan is missing the first device: '^$"le
}
if {! ~ $"le *aa:bb:cc:dd:ee:ff*public*-80*-*} {
	raise 'fail:lescan is missing the second device: '^$"le
}
v=`{cat $BT/status | grep '^scans '}
if {! ~ $"v 'scans 4'} {
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

# Conversations. clone yields a directory; connect to the mock's echo
# PSM waits for the L2CAP channel, then one SDU written is one SDU
# read back; hangup closes it; the last close frees the directory.
# The clone fd is held open for the block, as dial(2) holds it: a
# conversation lives while a file of it is open.
{
	id=`{read 10}
	if {! ftest -d $BT/$id} {
		raise 'fail:clone did not make a conversation directory'
	}
	for (f in ctl data status local remote listen) {
		if {! ftest -f $BT/$id/$f} {
			raise 'fail:conversation is missing '^$f
		}
	}
	v=`{cat $BT/$id/status}
	if {! ~ $"v Closed} {
		raise 'fail:new conversation status: '^$"v
	}
	echo 'connect 94:bb:43:44:61:04!0x1001' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after connect: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v '94:bb:43:44:61:04!4097'} {
		raise 'fail:remote: '^$"v
	}
	v=`{cat $BT/$id/local}
	if {! ~ $"v 'b8:27:eb:00:00:42!4097'} {
		raise 'fail:local: '^$"v
	}
	echo -n 'one sdu over l2cap' > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v 'one sdu over l2cap'} {
		raise 'fail:echo round trip: '^$"v
	}
	echo -n second > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v second} {
		raise 'fail:second round trip: '^$"v
	}
	echo hangup >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Closed} {
		raise 'fail:status after hangup: '^$"v
	}
	CONV=$id
} <> $BT/clone
sleep 1
if {ftest -d $BT/$CONV} {
	raise 'fail:conversation directory survived its last close'
}

# Refusals say why: a PSM the peer does not serve, a device that is
# not there.
{
	id=`{read 10}
	if {echo 'connect 94:bb:43:44:61:04!0x1005' >[1=0] >[2] /dev/null} {
		raise 'fail:connect to an unserved PSM succeeded'
	}
	v=`{cat $BT/$id/status}
	if {! ~ $"v 'Hangup connection refused: PSM not supported'} {
		raise 'fail:status after refusal: '^$"v
	}
} <> $BT/clone
{
	if {echo 'connect 00:11:22:33:44:55!0x1001' >[1=0] >[2] /dev/null} {
		raise 'fail:connect to an absent device succeeded'
	}
} <> $BT/clone
{
	if {echo 'connect nonsense' >[1=0] >[2] /dev/null} {
		raise 'fail:a malformed connect was accepted'
	}
} <> $BT/clone

# announce and listen: the mock's peer calls in on the PSM, the listen
# open returns with the accepted conversation's number, data flows
# both ways, and the peer records what it got.
{
	id=`{read 10}
	echo 'announce 0x1003' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Listen} {
		raise 'fail:status after announce: '^$"v
	}
	echo 'call 94:bb:43:44:61:04 0x1003 ping from peer' > $MNT/chan/btmockctl
	{
		nid=`{read 10}
		v=`{cat $BT/$nid/status}
		if {! ~ $"v Connected} {
			raise 'fail:accepted conversation status: '^$"v
		}
		v=`{cat $BT/$nid/remote}
		if {! ~ $"v '94:bb:43:44:61:04!4099'} {
			raise 'fail:accepted remote: '^$"v
		}
		v=`{read 100 < $BT/$nid/data}
		if {! ~ $"v 'ping from peer'} {
			raise 'fail:what the peer sent: '^$"v
		}
		echo -n 'pong from host' > $BT/$nid/data
		sleep 1
		v=`{cat $MNT/chan/btmockctl}
		if {! ~ $"v *'recv 94:bb:43:44:61:04 0x1003 pong from host'*} {
			raise 'fail:the peer did not record our reply: '^$"v
		}
	} < $BT/$id/listen
	if {echo 'announce 0x1003' >[1=0] >[2] /dev/null} {
		raise 'fail:announce on a Listen conversation was accepted'
	}
} <> $BT/clone

# A listener killed while its listen waits -- kill(1) on a process
# blocked in open(listen), which is how every listen(1) ends -- must
# take its announce with it. The pending open counted against the
# listener and a flushed open never counted off, so the PSM stayed
# "already announced" and the conversation lived on: four per battery
# run on the board (#632). Here: a subshell announces and blocks in the
# listen open; it is killed; the count is back and the PSM is free.
before=`{cat $BT/status | grep conversations}
{ id=`{read 20}; echo 'announce 0x1005' >[1=0]; read 10 < $BT/$id/listen } <> $BT/clone &
lpid=$apid
sleep 1
kill $lpid
sleep 1
after=`{cat $BT/status | grep conversations}
if {! ~ $"after $"before} {
	raise 'fail:a killed listener left its announce behind: '^$"before^' -> '^$"after
}
{
	if {! echo 'announce 0x1005' >[1=0]} {
		raise 'fail:the PSM a killed listener held was not released'
	}
} <> $BT/clone

# Pairing, the WiFi way: factotum is the only source of keys.
#
# A legacy device wants a PIN. With none in factotum the connection
# fails and says so; with "key proto=btpin addr=... !pin=..." written
# to factotum's ctl -- as a card file would be loaded -- it pairs, and
# the link key the controller made appears in factotum (elided) and
# in the keys file (whole). The next connection uses the key.
{
	if {echo 'connect aa:aa:aa:aa:aa:01!0x1001' >[1=0] >[2] /dev/null} {
		raise 'fail:paired with no PIN anywhere'
	}
} <> $BT/clone
echo 'key proto=btpin addr=aa:aa:aa:aa:aa:01 !pin=1234' > $FACT/ctl
{
	echo 'connect aa:aa:aa:aa:aa:01!0x1001' >[1=0]
	echo hangup >[1=0]
} <> $BT/clone
sleep 1
v=`{cat $FACT/ctl | grep 'proto=btlink addr=aa:aa:aa:aa:aa:01'}
if {~ $#v 0} {
	raise 'fail:the link key did not reach factotum'
}
v=`{cat $KEYS | grep 'proto=btlink addr=aa:aa:aa:aa:aa:01 type=0 !key='}
if {~ $#v 0} {
	raise 'fail:the link key did not reach the keys file'
}
{
	echo 'connect aa:aa:aa:aa:aa:01!0x1001' >[1=0]
	echo hangup >[1=0]
} <> $BT/clone
sleep 1

# Secure Simple Pairing with iocap none, the default: Just Works, and
# the key is kept.
{
	echo 'connect bb:bb:bb:bb:bb:02!0x1001' >[1=0]
	echo hangup >[1=0]
} <> $BT/clone
sleep 1
v=`{cat $KEYS | grep 'proto=btlink addr=bb:bb:bb:bb:bb:02 type=4'}
if {~ $#v 0} {
	raise 'fail:the SSP link key did not reach the keys file'
}

# forget: out of factotum and out of the file.
echo forget aa:aa:aa:aa:aa:01 > $BT/ctl
v=`{cat $FACT/ctl | grep 'proto=btlink addr=aa:aa:aa:aa:aa:01'}
if {! ~ $#v 0} {
	raise 'fail:forget left the key in factotum'
}
v=`{cat $KEYS | grep 'aa:aa:aa:aa:aa:01'}
if {! ~ $#v 0} {
	raise 'fail:forget left the key in the keys file'
}
v=`{cat /mnt/audit/log}
if {! ~ $"v 'bt9p forget peer=aa:aa:aa:aa:aa:01'*} {
	raise 'fail:forgetting a peer was not audited: '^$"v
}
v=`{cat $KEYS | grep 'bb:bb:bb:bb:bb:02'}
if {~ $#v 0} {
	raise 'fail:forget took the wrong key with it'
}

# iocap yesno: a numeric comparison is a line on pair, answered by a
# write. Nobody reading it is a no.
echo iocap yesno > $BT/ctl
{
	if {echo 'connect cc:cc:cc:cc:cc:03!0x1001' >[1=0] >[2] /dev/null} {
		raise 'fail:paired with a confirmation nobody could give'
	}
} <> $BT/clone
PAIR=/tmp/btns-pair
read 200 < $BT/pair > $PAIR &
sleep 1
{
	echo 'connect cc:cc:cc:cc:cc:03!0x1001' >[1=0]
	echo hangup >[1=0]
	echo confirmed-connected > /tmp/btns-confirmed
} <> $BT/clone &
sleep 2
v=`{cat $PAIR}
if {! ~ $"v 'confirm cc:cc:cc:cc:cc:03 123456'} {
	raise 'fail:the pair file did not show the confirmation: '^$"v
}
echo yes cc:cc:cc:cc:cc:03 > $BT/pair
sleep 2
v=`{cat /tmp/btns-confirmed}
if {! ~ $"v confirmed-connected} {
	raise 'fail:the connection did not complete after yes'
}
rm -f $PAIR /tmp/btns-confirmed

# pairable off, the default: a peer that calls and wants to pair is
# refused; pairable on lets it in.
echo iocap none > $BT/ctl
read 200 < $BT/pair > $PAIR &
{
	id=`{read 10}
	echo 'announce 0x1003' >[1=0]
	echo 'call dd:dd:dd:dd:dd:04 0x1003 knock' > $MNT/chan/btmockctl
	sleep 2
	v=`{cat $PAIR}
	if {! ~ $"v 'failed dd:dd:dd:dd:dd:04 pairing not allowed'} {
		raise 'fail:an uninvited pairing was not refused: '^$"v
	}
	echo pairable on > $BT/ctl
	echo 'call dd:dd:dd:dd:dd:04 0x1003 knock2' > $MNT/chan/btmockctl
	{
		nid=`{read 10}
		v=`{read 100 < $BT/$nid/data}
		if {! ~ $"v knock2} {
			raise 'fail:the call after pairing did not carry its text: '^$"v
		}
	} < $BT/$id/listen
} <> $BT/clone
echo pairable off > $BT/ctl
rm -f $PAIR $KEYS

# Serial ports: RFCOMM on the link's one multiplexer. The mock echoes
# on channel 1 and its SDP record says so, so "rfcomm1" and "spp" reach
# the same port; data is a byte stream, so one write may come back in
# one read; the multiplexer and its channel go when the last port does.
{
	id=`{read 10}
	echo 'connect 94:bb:43:44:61:04!rfcomm1' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after rfcomm connect: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v '94:bb:43:44:61:04!rfcomm1'} {
		raise 'fail:rfcomm remote: '^$"v
	}
	echo -n 'bytes over a serial port' > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v 'bytes over a serial port'} {
		raise 'fail:rfcomm echo round trip: '^$"v
	}
	echo hangup >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Closed} {
		raise 'fail:status after rfcomm hangup: '^$"v
	}
} <> $BT/clone
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:the link outlived its serial port: '^$"v
}
v=`{cat /mnt/audit/log}
if {! ~ $"v 'bt9p connect peer=94:bb:43:44:61:04 port=rfcomm1 outgoing'*} {
	raise 'fail:the serial connect was not audited: '^$"v
}

# "spp": the channel comes from the peer's SDP record
{
	id=`{read 10}
	echo 'connect 94:bb:43:44:61:04!spp' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after spp connect: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v '94:bb:43:44:61:04!rfcomm1'} {
		raise 'fail:spp resolved to the wrong channel: '^$"v
	}
	echo -n 'found by sdp' > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v 'found by sdp'} {
		raise 'fail:spp echo round trip: '^$"v
	}
	echo hangup >[1=0]
} <> $BT/clone

# a channel the peer does not serve is refused by DM, and says so
{
	id=`{read 10}
	if {echo 'connect 94:bb:43:44:61:04!rfcomm7' >[1=0] >[2] /dev/null} {
		raise 'fail:connect to an unserved RFCOMM channel succeeded'
	}
	v=`{cat $BT/$id/status}
	if {! ~ $"v 'Hangup refused'} {
		raise 'fail:status after rfcomm refusal: '^$"v
	}
	if {echo 'connect 94:bb:43:44:61:04!rfcomm31' >[1=0] >[2] /dev/null} {
		raise 'fail:an RFCOMM channel out of range was accepted'
	}
} <> $BT/clone

# announce spp: the first free channel, with a Serial Port record for
# peers to find; the mock's peer calls it and gets its bytes back
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:a link outlived the refused serial port: '^$"v
}
{
	id=`{read 10}
	if {echo 'announce 11:22:33:44:55:66!spp' >[1=0] >[2] /dev/null} {
		raise 'fail:announce on an address that is not ours was accepted'
	}
	echo 'announce *!spp' >[1=0]	# what announce(2) writes for bt!*!spp
	v=`{cat $BT/$id/status}
	if {! ~ $"v Listen} {
		raise 'fail:status after announce spp: '^$"v
	}
	v=`{cat $BT/$id/local}
	if {! ~ $"v 'b8:27:eb:00:00:42!rfcomm1'} {
		raise 'fail:announce spp did not take channel 1: '^$"v
	}
	echo 'call 94:bb:43:44:61:04 rfcomm1 serial from peer' > $MNT/chan/btmockctl
	{
		nid=`{read 10}
		v=`{cat $BT/$nid/status}
		if {! ~ $"v Connected} {
			raise 'fail:accepted serial conversation status: '^$"v
		}
		v=`{cat $BT/$nid/remote}
		if {! ~ $"v '94:bb:43:44:61:04!rfcomm1'} {
			raise 'fail:accepted serial remote: '^$"v
		}
		v=`{read 100 < $BT/$nid/data}
		if {! ~ $"v 'serial from peer'} {
			raise 'fail:what the serial peer sent: '^$"v
		}
		echo -n 'serial pong' > $BT/$nid/data
		sleep 1
		v=`{cat $MNT/chan/btmockctl}
		if {! ~ $"v *'recv 94:bb:43:44:61:04 rfcomm1 serial pong'*} {
			raise 'fail:the serial peer did not record our reply: '^$"v
		}
	} < $BT/$id/listen
} <> $BT/clone
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:a link outlived the serial call: '^$"v
}

# pair <addr>: a classic peer paired for its own sake -- the link made,
# secured (pairing on the way: this device demands SSP), the key kept,
# the link let go.
echo pairable on > $BT/ctl
echo pair cc:cc:cc:cc:cc:03 > $BT/ctl
v=`{cat $FACT/ctl | grep 'proto=btlink addr=cc:cc:cc:cc:cc:03'}
if {~ $#v 0} {
	raise 'fail:pair did not leave a key in factotum: '^`{cat $FACT/ctl}
}
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:the link made for pairing was not let go: '^$"v
}
if {echo pair 00:11:22:33:44:55 > $BT/ctl >[2] /dev/null} {
	raise 'fail:pairing with a device that is not there succeeded'
}
echo pairable off > $BT/ctl

# LE: a mouse. lescan hears it; connect <addr>!hid pairs (Just Works,
# the LTK into factotum and the keys file), finds the HID service,
# subscribes to the boot report, and a report the device notifies is
# one read. A second connect encrypts with the stored LTK and pairs
# no more. connect <addr>!gatt is the raw ATT channel.
echo pairable on > $BT/ctl
v=`{cat $BT/lescan | grep 'ee:ee:ee:ee:ee:05'}
if {! ~ $"v 'ee:ee:ee:ee:ee:05 random -55 mockmouse'} {
	raise 'fail:lescan did not hear the mouse as random: '^$"v
}
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:05!hid' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v 'Connected boot-mouse'} {
		raise 'fail:status after hid connect: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v 'ee:ee:ee:ee:ee:05!hid'} {
		raise 'fail:hid remote: '^$"v
	}
	v=`{cat $FACT/ctl | grep 'proto=btltk' | grep 'addr=ee:ee:ee:ee:ee:05'}
	if {~ $#v 0} {
		raise 'fail:the LTK did not reach factotum: '^`{cat $FACT/ctl}
	}
	v=`{cat $KEYS | grep 'proto=btltk addr=ee:ee:ee:ee:ee:05 type=1 ediv=4660 rand=030405060708090a'}
	if {~ $#v 0} {
		raise 'fail:the LTK did not reach the keys file with its EDIV and Rand: '^`{cat $KEYS}
	}
	echo 'notify ee:ee:ee:ee:ee:05 01 05 fb' > $MNT/chan/btmockctl
	v=`{read 100 < $BT/$id/data | xd -1x}
	if {! ~ $"v *'01 05 fb'*} {
		raise 'fail:the boot report did not arrive as one read: '^$"v
	}
	if {echo -n x > $BT/$id/data >[2] /dev/null} {
		raise 'fail:writing to a hid conversation was accepted'
	}
	echo hangup >[1=0]
} <> $BT/clone
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:the LE link outlived its conversation: '^$"v
}
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:05!gatt' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after gatt connect on the stored LTK: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v 'ee:ee:ee:ee:ee:05!gatt'} {
		raise 'fail:gatt remote: '^$"v
	}
} <> $BT/clone
# a mouse with no boot report: its Report Map is read and parsed, the
# report id learnt from the Report Reference, and each report handed on
# in the boot layout -- status says "mouse", and the reader is none the
# wiser. id 26: button 1, X -3, Y 5, wheel -1 (hid_test's vector)
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:06!hid' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v 'Connected mouse'} {
		raise 'fail:status after a report-protocol hid connect: '^$"v
	}
	echo 'notify ee:ee:ee:ee:ee:06 01 fd 5f 00 ff' > $MNT/chan/btmockctl
	v=`{read 100 < $BT/$id/data | xd -1x}
	if {! ~ $"v *'01 fd 05 ff'*} {
		raise 'fail:the report was not handed on in the boot layout: '^$"v
	}
	echo hangup >[1=0]
} <> $BT/clone
# An LE credit-based channel: what a phone's app is given, and what 9P
# to one will ride on (#647). The link is the mouse's, already bonded,
# so it is encrypted from the stored LTK and the channel is allowed; the
# mock echoes on le128. An SDU of 1500 bytes is three K-frames each way.
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:05!le0x80' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after an LE channel connect: '^$"v
	}
	v=`{cat $BT/$id/remote}
	if {! ~ $"v 'ee:ee:ee:ee:ee:05!le128'} {
		raise 'fail:LE channel remote: '^$"v
	}
	echo -n le-channel-echo > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v le-channel-echo} {
		raise 'fail:LE channel echo: '^$"v
	}
	# larger than the MPS, so it is segmented and reassembled both ways
	dd -if /dis/sh.dis -bs 1500 -count 1 > /tmp/btns.le.out >[2] /dev/null
	cat /tmp/btns.le.out > $BT/$id/data
	read 2000 < $BT/$id/data > /tmp/btns.le.in
	if {! cmp -s /tmp/btns.le.out /tmp/btns.le.in} {
		raise 'fail:a 1500-byte SDU did not survive the LE channel'
	}
	# and a write longer than the peer's MTU (2048) goes as several SDUs,
	# in order: it is a byte stream to a phone, and 9P's messages are
	# longer than any SDU. 5000 bytes come back as 2048, 2048 and 904.
	dd -if /dis/sh.dis -bs 5000 -count 1 > /tmp/btns.le.out >[2] /dev/null
	cat /tmp/btns.le.out > $BT/$id/data
	{read 2048 < $BT/$id/data; read 2048 < $BT/$id/data; read 2048 < $BT/$id/data} > /tmp/btns.le.in
	if {! cmp -s /tmp/btns.le.out /tmp/btns.le.in} {
		raise 'fail:5000 bytes did not survive the LE channel as a stream'
	}
	# a PSM the peer never announced
	echo hangup >[1=0]
} <> $BT/clone
{
	id=`{read 10}
	if {echo 'connect ee:ee:ee:ee:ee:05!le0x99' >[1=0] >[2] /dev/null} {
		raise 'fail:an LE channel to an unannounced PSM was not refused'
	}
	v=`{cat $BT/$id/status}
	if {! ~ $"v 'Hangup connection refused: PSM not supported'} {
		raise 'fail:status after a refused LE channel: '^$"v
	}
	if {echo 'connect ee:ee:ee:ee:ee:05!le0' >[1=0] >[2] /dev/null} {
		raise 'fail:le0 was taken for a PSM'
	}
	if {echo 'connect ee:ee:ee:ee:ee:05!le256' >[1=0] >[2] /dev/null} {
		raise 'fail:le256 was taken for a PSM: an LE PSM is one byte'
	}
} <> $BT/clone
# LE Secure Connections (#647): a peer that offers it is paired with it.
# With iocap none that is Just Works over ECDH; the LTK is one both ends
# computed and neither sent, so it has EDIV 0 and Rand 0 and is kept all
# the same -- the next connection encrypts from it with no pairing.
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:07!le0x80' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:status after a Secure Connections pairing: '^$"v
	}
	echo -n over-sc > $BT/$id/data
	v=`{read 100 < $BT/$id/data}
	if {! ~ $"v over-sc} {
		raise 'fail:echo on a link secured by Secure Connections: '^$"v
	}
	v=`{cat $KEYS | grep 'proto=btltk addr=ee:ee:ee:ee:ee:07 type=1 ediv=0 rand=0000000000000000'}
	if {~ $#v 0} {
		raise 'fail:the Secure Connections LTK was not kept: '^`{cat $KEYS}
	}
	echo hangup >[1=0]
} <> $BT/clone
sleep 1
{
	id=`{read 10}
	echo 'connect ee:ee:ee:ee:ee:07!le0x80' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Connected} {
		raise 'fail:reconnecting on the stored Secure Connections LTK: '^$"v
	}
	echo hangup >[1=0]
} <> $BT/clone
sleep 1
# iocap yesno: both ends can show digits, so they are compared. The six
# digits are a line on pair; yes lets the pairing finish.
echo 'forget ee:ee:ee:ee:ee:07' > $BT/ctl
echo iocap yesno > $BT/ctl
{
	if {echo 'connect ee:ee:ee:ee:ee:07!le0x80' >[1=0] >[2] /dev/null} {
		raise 'fail:an LE pairing went through with digits nobody could compare'
	}
} <> $BT/clone
sleep 1
read 200 < $BT/pair > $PAIR &
sleep 1
{
	echo 'connect ee:ee:ee:ee:ee:07!le0x80' >[1=0]
	echo hangup >[1=0]
	echo sc-confirmed > /tmp/btns-confirmed
} <> $BT/clone &
sleep 8
v=`{cat $PAIR}
if {! ~ $"v 'confirm ee:ee:ee:ee:ee:07 '[0-9][0-9][0-9][0-9][0-9][0-9]} {
	raise 'fail:the pair file did not show six digits for the LE pairing: '^$"v
}
echo yes ee:ee:ee:ee:ee:07 > $BT/pair
sleep 4
v=`{cat /tmp/btns-confirmed}
if {! ~ $"v sc-confirmed} {
	raise 'fail:the LE connection did not complete after yes'
}
rm -f $PAIR /tmp/btns-confirmed
echo iocap none > $BT/ctl

# Being an LE peripheral (#647): what lets a phone's app find the board
# and mount it with no network. Off unless told; "announce le9p" takes a
# dynamic PSM and publishes it in InferNode's GATT service, readable
# only on an encrypted link, which is how a phone is made to pair. The
# mock's phone connects only to a host advertising that service, finds
# it, is refused the PSM, pairs with Secure Connections (we are the
# responder, and the controller asks us for the key), reads the PSM,
# opens the channel and sends its text.
v=`{grep '^advertising' $BT/status}
if {! ~ $"v 'advertising 0'} {
	raise 'fail:a board advertises without having been told to: '^$"v
}
if {echo 'lecall a0:a0:a0:a0:a0:01 too-early' > $MNT/chan/btmockctl >[2] /dev/null} {
	raise 'fail:the phone found a board that was not advertising'
}
{
	id=`{read 10}
	echo 'announce le9p' >[1=0]
	v=`{cat $BT/$id/local}
	if {! ~ $"v *'!le128'} {
		raise 'fail:le9p did not take the first dynamic LE PSM: '^$"v
	}
	{
		id2=`{read 10}
		if {echo 'announce le9p' >[1=0] >[2] /dev/null} {
			raise 'fail:le9p was announced twice'
		}
		if {echo 'connect ee:ee:ee:ee:ee:05!le9p' >[1=0] >[2] /dev/null} {
			raise 'fail:le9p was dialled: it is a thing announced'
		}
	} <> $BT/clone
	echo advertise on > $BT/ctl
	sleep 1
	v=`{grep '^advertising' $BT/status}
	if {! ~ $"v 'advertising 1'} {
		raise 'fail:status after advertise on: '^$"v
	}
	# pairable off, the default: the phone may look, and may not pair
	echo pairable off > $BT/ctl
	echo 'lecall a0:a0:a0:a0:a0:01 refused' > $MNT/chan/btmockctl
	sleep 3
	v=`{cat $KEYS | grep 'a0:a0:a0:a0:a0:01'}
	if {! ~ $#v 0} {
		raise 'fail:a phone paired with a board that was not pairable: '^$"v
	}
} <> $BT/clone
sleep 1
echo pairable on > $BT/ctl
{
	id=`{read 10}
	echo 'announce le9p' >[1=0]
	echo advertise on > $BT/ctl
	sleep 1
	echo 'lecall a0:a0:a0:a0:a0:02 hello from the phone' > $MNT/chan/btmockctl
	{
		nid=`{read 10}
		v=`{cat $BT/$nid/remote}
		if {! ~ $"v 'a0:a0:a0:a0:a0:02!le128'} {
			raise 'fail:the phone''s conversation: remote '^$"v
		}
		v=`{cat $BT/$nid/status}
		if {! ~ $"v Connected} {
			raise 'fail:the phone''s conversation: status '^$"v
		}
		v=`{read 100 < $BT/$nid/data}
		if {! ~ $"v 'hello from the phone'} {
			raise 'fail:what the phone sent did not arrive: '^$"v
		}
	} <> $BT/$id/listen
	v=`{cat $KEYS | grep 'proto=btltk addr=a0:a0:a0:a0:a0:02 type=1 ediv=0 rand=0000000000000000'}
	if {~ $#v 0} {
		raise 'fail:the key made with the phone was not kept: '^`{cat $KEYS}
	}
} <> $BT/clone
echo advertise off > $BT/ctl
v=`{grep '^advertising' $BT/status}
if {! ~ $"v 'advertising 0'} {
	raise 'fail:status after advertise off: '^$"v
}
sleep 2

# announcing one: classic and LE PSMs are separate number spaces
{
	id=`{read 10}
	echo 'announce le0x81' >[1=0]
	v=`{cat $BT/$id/status}
	if {! ~ $"v Listen} {
		raise 'fail:status after announce le0x81: '^$"v
	}
	v=`{cat $BT/$id/local}
	if {! ~ $"v *'!le129'} {
		raise 'fail:local of an LE listener: '^$"v
	}
	{
		id2=`{read 10}
		if {echo 'announce le129' >[1=0] >[2] /dev/null} {
			raise 'fail:the same LE PSM was announced twice'
		}
		echo 'announce 0x1081' >[1=0]
	} <> $BT/clone
} <> $BT/clone
echo pairable off > $BT/ctl

# dial(2), unchanged: the kernel's dial against this tree. The dial
# command runs its argument with the connection on fds 0 and 1.
v=`{dial -A $MNT/bt^'!94:bb:43:44:61:04!4097' sh -c 'echo -n via-dial; read 100 >[1=2]' >[2=1]}
if {! ~ $"v via-dial} {
	raise 'fail:dial(2) round trip: '^$"v
}
sleep 1
v=`{cat $BT/status | grep '^links '}
if {! ~ $"v 'links 0'} {
	raise 'fail:a link outlived every conversation on it: '^$"v
}
v=`{cat $BT/status | grep '^conversations '}
if {! ~ $"v 'conversations 0'} {
	raise 'fail:conversations outlived their files: '^$"v
}

echo PASS
