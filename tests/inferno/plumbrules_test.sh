#!/dis/sh.dis
#
# lib/sh/plumbrules: the plumber reads the user's rules
# (/usr/<user>/lib/plumbing) first and the defaults after, so a user's
# rule overrides a default and the defaults take what the user's rules
# do not; a user file that does not parse is left out at start, and at
# load the plumber keeps the rules it had.
#
# The user's home is a scratch directory bound over /usr, so no real
# rules are read or written.
#
# tests/host/plumbrules_test.sh runs this.

load std

T=/tmp/plumbrules_test
user=`{cat /dev/user}
failed=0

fn pass {
	echo 'PASS:' $*
}

fn fail {
	echo 'FAIL:' $*
	failed=1
}

# The port a message ($1) was plumbed to: the receivers (receive,
# below) write what each port is sent to $T/rx.<port>
fn portfor {
	msg := $1
	plumb $msg >[2] /dev/null
	sleep 1
	got := ()
	for p in mine theirs {
		if {grep -s $msg $T/rx.^$p} {
			got = $got $p
		}
	}
	echo $got
}

# A receiver on each port: a "start" to the plumber, as plumbmsg's init
# sends, then the port read for good
fn receive {
	for p in mine theirs {
		plumb -s $p -d plumb start
		{
			cat /chan/plumb.^$p > $T/rx.^$p >[2] /dev/null
		} &
	}
	sleep 1
}

rm -rf $T
mkdir -p $T/usr/^$user^/lib
bind -b $T/usr /usr

echo 'kind is text
data matches ''x[0-9]+''
plumb to theirs

kind is text
data matches ''y[0-9]+''
plumb to theirs' > $T/defaults

echo 'kind is text
data matches ''x[0-9]+''
plumb to mine' > /usr/^$user^/lib/plumbing

# start: the user's rules first
bind -c '#splumber1' /chan
/lib/sh/plumbrules start $T/defaults
receive
rules="{cat /chan/plumb.rules}
if {~ $rules *'plumb to mine'*'plumb to theirs'*} {
	pass 'start: the user''s rules, then the defaults'
} {
	fail 'start: rules:' $rules
}
x1=`{portfor x1}
if {~ $x1 mine} {
	pass 'a user''s rule overrides a default'
} {
	fail 'x1 went to' $x1
}
y1=`{portfor y1}
if {~ $y1 theirs} {
	pass 'the defaults take what the user''s rules do not'
} {
	fail 'y1 went to' $y1
}

# load: the user's rules again, edited
echo 'kind is text
data matches ''y[0-9]+''
plumb to mine' > /usr/^$user^/lib/plumbing
if {/lib/sh/plumbrules load $T/defaults} {
	rules="{cat /chan/plumb.rules}
	if {~ $rules *'y\[0-9\]+'*'plumb to mine'*} {
		pass 'load: the edited rules replace the old'
	} {
		fail 'load: rules:' $rules
	}
} {
	fail 'load failed'
}

# load, a broken file: the rules stay as they were
echo 'kind is text
data rubbish here
plumb to mine' > /usr/^$user^/lib/plumbing
cat /chan/plumb.rules > $T/before
if {/lib/sh/plumbrules load $T/defaults >[2] /dev/null} {
	fail 'load took a broken file'
} {
	cat /chan/plumb.rules > $T/after
	# (cmp, not ~: the rules hold pattern characters)
	if {cmp -s $T/before $T/after} {
		pass 'load: a broken file is refused, the rules kept'
	} {
		fail 'load: the rules changed'
	}
}

# start, a broken file: the defaults alone
bind -c '#splumber2' /chan
/lib/sh/plumbrules start $T/defaults >[2] $T/err
rules="{cat /chan/plumb.rules}
if {~ $rules *'plumb to theirs'* && ! ~ $rules *'plumb to mine'*} {
	pass 'start: a broken file is left out, the defaults used'
} {
	fail 'start with a broken file: rules:' $rules
}
if {grep -s 'not used' $T/err} {
	pass 'and the user is told'
} {
	fail 'no message about the broken file'
}

# no file: the defaults alone
rm /usr/^$user^/lib/plumbing
bind -c '#splumber3' /chan
/lib/sh/plumbrules start $T/defaults
rules="{cat /chan/plumb.rules}
if {~ $rules *'plumb to theirs'* && ! ~ $rules *'plumb to mine'*} {
	pass 'start with no user file: the defaults'
} {
	fail 'start with no user file: rules:' $rules
}

unmount $T/usr /usr
rm -rf $T
if {~ $failed 1} {
	raise 'fail:tests failed'
}
echo 'ALL PASS'
