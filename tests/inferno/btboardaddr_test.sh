#!/dis/sh.dis
# btboardaddr(1): a Raspberry Pi 3's Bluetooth controller given the
# board's own address. A 3B+'s CYW43455 has none: after its patch it
# reports 43:45:c0:00:1f:ac, the same on every board, and a 3B+ booted
# from a release card did exactly that. Raspberry Pi OS's rule, which
# this follows, is b8:27:eb and the serial's low three bytes ^ 0xaa;
# that board's serial, 0xfaca4c8e, makes b8:27:eb:60:e6:24.
#
# Over btmock(4), so no radio: a controller at the patch's default
# with a serial on the command line is given the board's address; one
# with no serial is left, and says why; one with an address of its own
# (a 4B's) is left alone; and asking twice changes nothing.

load std

for f in /dis/bt9p.dis /dis/btmock.dis /dis/btboardaddr.dis {
	if {! ftest -f $f} {
		raise 'skip:'^$f^' not built'
	}
}

T=/tmp/btboardaddr
mkdir -p $T

# a command line as a 3B+'s firmware writes it, and one with no serial
echo 'bcm2708_fb.fbwidth=656 bcm2709.boardrev=0xa020d3 bcm2709.serial=0xfaca4c8e smsc95xx.macaddr=B8:27:EB:CA:4C:8E console=ttyAMA0,115200' > $T/args3b
echo 'console=ttyAMA0,115200 root=/dev/mmcblk0p2' > $T/argsnone

# up <dir> <controller address>: a mock controller there, bt9p over it, up
fn up {
	d=$1
	mkdir -p $d/chan
	btmock -a $2 $d/chan/btmock &
	sleep 1
	bt9p -t $d/chan/btmock -m $d -k $d/keys
	echo up > $d/bt/ctl
}

# the 3B+: the patch's default, a serial to make the board's from
up $T/3b 43:45:c0:00:1f:ac
v=`{cat $T/3b/bt/addr}
if {! ~ $"v '43:45:c0:00:1f:ac'} {
	raise 'fail:the mock 3B+ did not start at the patch default: '^$"v
}
btboardaddr -m $T/3b/bt -b $T/args3b
v=`{cat $T/3b/bt/addr}
if {! ~ $"v 'b8:27:eb:60:e6:24'} {
	raise 'fail:a 3B+ at the patch default was not given b8:27:eb:60:e6:24: '^$"v
}
# twice: it is the board's now, and is left alone
btboardaddr -m $T/3b/bt -b $T/args3b
v=`{cat $T/3b/bt/addr}
if {! ~ $"v 'b8:27:eb:60:e6:24'} {
	raise 'fail:a second btboardaddr changed the board address: '^$"v
}

# no serial on the command line: left at the default, and it says so
up $T/noserial 43:45:c0:00:1f:ac
if {btboardaddr -m $T/noserial/bt -b $T/argsnone >[2] $T/noserial.err} {
	raise 'fail:btboardaddr succeeded with no serial to make an address from'
}
v=`{cat $T/noserial/bt/addr}
if {! ~ $"v '43:45:c0:00:1f:ac'} {
	raise 'fail:the address changed with no serial: '^$"v
}
v=`{grep -i 'no bcm2709.serial' $T/noserial.err}
if {~ $#v 0} {
	raise 'fail:no serial, and btboardaddr did not say so'
}

# a 4B: its controller has an address of its own, which is kept
up $T/4b 88:a2:9e:c1:92:4d
btboardaddr -m $T/4b/bt -b $T/args3b
v=`{cat $T/4b/bt/addr}
if {! ~ $"v '88:a2:9e:c1:92:4d'} {
	raise 'fail:a controller with its own address was given another: '^$"v
}

echo PASS
