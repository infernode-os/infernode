#!/dis/sh.dis
#
# End to end, less the radio and the phone's own stack (#647): a board
# with no network exports setupfs(4) over an LE channel announced as
# le9p; a phone finds the service, pairs, opens the channel, MOUNTS the
# tree through it as 9P, reads what the board says of itself and gives
# it a Wi-Fi configuration. The board's side is bt9p(4), listen(1),
# export(4) and setupfs(4) exactly as the board will run them; the
# phone is btmock(4)'s, relaying its channel to a file that mount(1)
# speaks 9P to. Proves that 9P rides the channel, whose SDUs are far
# shorter than its messages.
#

load std

for (d in bt9p btmock setupfs) {
	if {! ftest -f /dis/$d.dis} {
		raise 'skip:'^$d^'.dis not built'
	}
}
if {! ftest -f /dis/auth/factotum.dis} {
	raise 'skip:no factotum'
}

T=/tmp/btsetup
rm -rf $T >[2] /dev/null
C=/tmp/btsetup-card	# the card's files; not under $T, which bt9p mounts over
rm -rf $C >[2] /dev/null
mkdir -p $T/chan $T/factotum $T/setup $T/board $C/ipifc/0
echo 'device /net/ether0 maxtu 1514 unbound' > $C/ipifc/0/status
echo 'wpa: no network configured' > $C/wpa.log
echo -n > $C/sysctl

btmock -a 'b8:27:eb:00:00:42' -t 100 -H $T/hcd $T/chan/btmock &
sleep 1
auth/factotum -m $T/factotum
sleep 1
# the key file is kept out of $T: bt9p mounts its tree over $T as a union, and
# a key file inside it would have bt9p walking into itself to save a key
KEYS=/tmp/btsetup-keys
rm -f $KEYS
bt9p -t $T/chan/btmock -m $T -f $T/factotum -k $KEYS
sleep 1
BT=$T/bt
echo up > $BT/ctl
sleep 1

# the board's side, as it will be run
mount {setupfs -w $C/wifi -c $C/sysctl -n $C/ipifc -l $C/wpa.log} $T/setup
echo pairable on > $BT/ctl
listen -A $T/bt^'!*!le9p' {export $T/setup} &
sleep 2
echo advertise on > $BT/ctl
sleep 1

# the phone: finds the board, pairs, opens the channel, and then says nothing of its own
echo 'lecall a0:a0:a0:a0:a0:09 -relay' > $T/chan/btmockctl
# pairing is two P-256 operations a side, seconds each in an emulator:
# wait for the key to be kept, which is the pairing done, then for the
# channel the phone opens next
paired=no
for (i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30) {
	if {~ $paired no} {
		if {grep -s 'a0:a0:a0:a0:a0:09' $KEYS >[2] /dev/null} {
			paired=yes
		} {
			sleep 2
		}
	}
}
if {~ $paired no} {
	raise 'fail:the phone did not pair within a minute'
}
sleep 3

mount -A $T/chan/btmockphone $T/board
v=`{ls $T/board}
if {! ~ $"v *wifi*} {
	raise 'fail:the board''s tree did not mount over the channel: '^$"v
}
v=`{cat $T/board/wifi}
if {! ~ $"v unconfigured} {
	raise 'fail:wifi, read over Bluetooth: '^$"v
}
v=`{cat $T/board/net}
if {! ~ $"v *'/net/ether0'*unbound*} {
	raise 'fail:net, read over Bluetooth: '^$"v
}
v=`{cat $T/board/log}
if {! ~ $"v *'no network configured'*} {
	raise 'fail:log, read over Bluetooth: '^$"v
}
echo 'essid Set From A Phone
password over bluetooth le' > $T/board/wifi
v=`{cat $C/wifi}
if {! ~ $"v 'essid Set From A Phone password over bluetooth le'} {
	raise 'fail:the configuration written over Bluetooth did not reach the card: '^$"v
}
if {echo 'essid Bad' > $T/board/wifi >[2] /dev/null} {
	raise 'fail:a bad configuration was accepted over Bluetooth'
}
echo reboot > $T/board/ctl
v=`{cat $C/sysctl}
if {! ~ $"v reboot} {
	raise 'fail:reboot, written over Bluetooth, did not arrive: '^$"v
}
# something far longer than an SDU: the log, made some 20 KB (setupfs serves 32 KB of one)
dd -if /dis/sh.dis -bs 5000 -count 1 >[2] /dev/null | xd -c > $C/wpa.log
cat $T/board/log | sed 1d > $C/log.got
if {! cmp -s $C/wpa.log $C/log.got} {
	raise 'fail:a long read over Bluetooth was damaged'
}
unmount $T/board
rm -f $KEYS
rm -rf $C >[2] /dev/null
echo PASS
