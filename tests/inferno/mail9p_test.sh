#!/dis/sh.dis
#
# mail9p — integration smoke test
#
# Verifies that mail9p mounts at /mnt/mail, exposes the documented
# namespace shape, and rejects bad ctl writes. Live IMAP/SMTP
# coverage requires factotum credentials and a reachable mail
# server; that's out of scope for this offline test.
#

load std

failed=0

fn fail {
	failed=1
	echo 'FAIL:' $*
}

fn passlog {
	echo 'PASS:' $*
}

fn assert_exists {
	if {test -e $1} {
		passlog 'exists' $1
	} {
		fail 'missing path' $1
	}
}

fn assert_writefails {
	# echo $1 to $2 should fail (mail9p rejects it).
	if {echo $1 > $2 >[2] /dev/null} {
		fail 'write `'^$1^'` to' $2 'unexpectedly succeeded'
	} {
		passlog 'rejected write `'^$1^'` to' $2
	}
}

echo '=== mail9p integration smoke test ==='

# Environmental skip-guard (INFR-312): mail9p mounts at /mnt/mail, which
# needs an mntgen-backed /mnt. A bare runner has no /mnt mntgen, so the
# mount fails ("can't ensuredir /mnt/mail") and every assertion below
# misses. Establish /mnt here — wrapped in `if {! ...}` so its failure is
# caught as status — and skip cleanly when it can't be set up. In a full
# runtime /mnt already exists and this exercises mail9p for real.
if {! mount -ac {mntgen} /mnt} {
	raise 'skip:cannot set up /mnt (mntgen) — needs a full runtime to mount /mnt/mail'
}

# Start mail9p; it mounts at /mnt/mail in this namespace before returning.
mail9p
sleep 1

# Namespace shape
assert_exists /mnt/mail
assert_exists /mnt/mail/ctl
assert_exists /mnt/mail/accounts

# /ctl is write-only-style; reads return empty.
ctlbytes=`{cat /mnt/mail/ctl >[2] /dev/null}
if {~ $#ctlbytes 0} {
	passlog '/mnt/mail/ctl reads as empty'
} {
	fail '/mnt/mail/ctl returned data:' $ctlbytes
}

# Empty accounts dir.
acctlist=`{ls /mnt/mail/accounts >[2] /dev/null}
if {~ $#acctlist 0} {
	passlog 'accounts/ is empty'
} {
	fail 'accounts/ unexpectedly contains' $acctlist
}

# Reject bad ctl verbs.
assert_writefails bogus /mnt/mail/ctl
assert_writefails 'disconnect ghost' /mnt/mail/ctl
assert_writefails 'sync ghost' /mnt/mail/ctl

# A valid-looking connect to an unresolvable host should error out
# cleanly (factotum lookup or DNS resolution failure).
assert_writefails 'connect testacct mail.invalid' /mnt/mail/ctl

# Account slot should NOT linger after the failed connect.
acctlist=`{ls /mnt/mail/accounts >[2] /dev/null}
if {~ $#acctlist 0} {
	passlog 'accounts/ still empty after failed connect (slot rolled back)'
} {
	fail 'accounts/' $acctlist 'lingered after failed connect'
}

echo ''
if {~ $failed 0} {
	echo '=== ALL PASS ==='
} {
	echo '=== FAILURES ==='
	raise 'fail: mail9p integration smoke'
}
