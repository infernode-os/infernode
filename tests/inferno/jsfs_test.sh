#!/dis/sh.dis
#
# jsfs(4): JavaScript realms as files.  A realm made by reading clone,
# a script run through eval and its value read back, an error, what
# the scripts printed, the status, a ctl verb refused, realms kept
# apart, and kill taking the realm's directory away.
#

load std

failed=0

fn fail {
	echo 'FAIL:' $*
	failed=1
}

# starts got prefix message
fn starts {
	if {~ $1 $2^*} {
		echo 'PASS:' $3
	} {
		fail $3 '(got' $1 'want' $2 '...)'
	}
}

# want got expected message (got and expected each one word: quote lists with $")
fn want {
	if {~ $1 $2} {
		echo 'PASS:' $3
	} {
		fail $3 '(got' $1 'want' $2 ')'
	}
}

if {! ftest -f /dis/jsfs.dis} {
	raise 'skip:jsfs.dis not built'
}
mkdir -p /tmp/jsfstest
jsfs -m /tmp/jsfstest
M=/tmp/jsfstest

a=`{cat $M/clone}
b=`{cat $M/clone}
want $a 1 'clone makes realm 1'
want $b 2 'and then realm 2'

echo 'var x = 6 * 7; print("printed", x); [1, 2, 3].map(v => v * 2)' > $M/$a/eval
r=`{cat $M/$a/eval}
want $"r 2,4,6 'eval gives the value'
r=`{cat $M/$a/console}
want $"r 'printed 42' 'console has what was printed'

echo 'typeof x' > $M/$b/eval
r=`{cat $M/$b/eval}
want $"r undefined 'realms are apart'

echo 'null.y' > $M/$a/eval
r=`{cat $M/$a/eval}
starts $"r 'error: TypeError' 'a thrown error is an error line'

s=`{cat $M/$a/status}
starts $"s 'idle scripts 2' 'status: idle, two scripts run'

if {echo 'bogus' > $M/$a/ctl} {
	fail 'an unknown ctl verb was taken'
} {
	echo 'PASS: an unknown ctl verb is refused'
}

echo 'var got = "pending"; import("/NOTICE").then(() => got = "loaded", e => got = "refused"); 0' > $M/$a/eval
echo 'got' > $M/$a/eval
r=`{cat $M/$a/eval}
want $"r refused 'a module cannot be imported'

echo kill > $M/$a/ctl
if {ftest -d $M/$a} {
	fail 'kill left the directory'
} {
	echo 'PASS: kill takes the realm away'
}

if {~ $failed 0} {
	echo 'ALL PASS'
} {
	echo 'FAILURES ABOVE'
	raise 'fail:jsfs'
}
