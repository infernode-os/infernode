#!/dis/sh.dis
#
# Namespace-contract test for countfs(4), the tutorial service from
# docs/TUTORIAL-9P-SERVICE.md.  Asserts the served tree, the ctl
# verbs, the text data formats, and that the file modes enforce the
# access policy (write-only ctl, read-only value/log).
#

load std

if {! ftest -f /dis/countfs.dis} {
	raise 'skip:countfs.dis not built'
}

# /tmp is writable in every test environment; a booted system with
# mntgen on /mnt would use /mnt/count instead.
MNT=/tmp/count
mkdir -p $MNT
mount {countfs} $MNT

if {! ftest -f $MNT/ctl} {
	raise 'fail:ctl missing after mount'
}
if {! ftest -f $MNT/value} {
	raise 'fail:value missing after mount'
}
if {! ftest -f $MNT/log} {
	raise 'fail:log missing after mount'
}

# Initial value is 0.
v=`{cat $MNT/value}
if {! ~ $"v 0} {
	raise 'fail:initial value not 0: '^$"v
}

# add and set change the count.
echo add 5 > $MNT/ctl
echo add 2 > $MNT/ctl
v=`{cat $MNT/value}
if {! ~ $"v 7} {
	raise 'fail:expected 7 after add 5 + add 2, got '^$"v
}

echo set 100 > $MNT/ctl
v=`{cat $MNT/value}
if {! ~ $"v 100} {
	raise 'fail:expected 100 after set, got '^$"v
}

echo reset > $MNT/ctl
v=`{cat $MNT/value}
if {! ~ $"v 0} {
	raise 'fail:expected 0 after reset, got '^$"v
}

# The log has one line per change (4 so far), fields space-separated,
# RFC 3339 timestamp first, then verb old new.
lines=`{wc -l < $MNT/log}
if {! ~ $"lines 4} {
	raise 'fail:expected 4 log lines, got '^$"lines
}
lastverb=`{tail -1 $MNT/log | awk '{print $2}'}
if {! ~ $"lastverb reset} {
	raise 'fail:last log verb not reset: '^$"lastverb
}

# An unknown verb is rejected.
if {echo bogus > $MNT/ctl >[2] /dev/null} {
	raise 'fail:unknown ctl verb was accepted'
}

# Modes are the access policy: ctl is write-only, value read-only.
# The failing open must happen inside the command (cat/cp), not in a
# sh redirection: a failed sh redirection raises and aborts the script
# even inside an if-block.
if {cat $MNT/ctl > /dev/null >[2] /dev/null} {
	raise 'fail:ctl is readable (mode should be 222)'
}
if {cp /dev/null $MNT/value >[2] /dev/null} {
	raise 'fail:value is writable (mode should be 444)'
}

unmount $MNT
echo PASS
