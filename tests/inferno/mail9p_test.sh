#!/dis/sh.dis
#
# mail9p — integration smoke test
#
# Verifies that mail9p mounts at /n/mail, exposes the documented
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

fn assert_writeok {
	# echo $1 to $2 should succeed (mail9p accepts it).
	if {echo $1 > $2 >[2] /dev/null} {
		passlog 'accepted write `'^$1^'` to' $2
	} {
		fail 'write `'^$1^'` to' $2 'unexpectedly failed'
	}
}

echo '=== mail9p integration smoke test ==='

# Environmental skip-guard (INFR-312): mail9p mounts at /n/mail, which
# needs an mntgen-backed /n. A bare runner has no /n mountpoint, so the
# mount fails ("can't ensuredir /n/mail") and every assertion below
# misses. Establish /n here — wrapped in `if {! ...}` so its failure is
# caught as status — and skip cleanly when it can't be set up. In a full
# runtime /n already exists and this exercises mail9p for real.
if {! mount -ac {mntgen} /n} {
	raise 'skip:cannot set up /n (mntgen) — needs a full runtime to mount /n/mail'
}

# Start mail9p; it mounts at /n/mail in this namespace before returning.
mail9p
sleep 1

# Namespace shape
assert_exists /n/mail
assert_exists /n/mail/ctl
assert_exists /n/mail/accounts

# /ctl is write-only-style; reads return empty.
ctlbytes=`{cat /n/mail/ctl >[2] /dev/null}
if {~ $#ctlbytes 0} {
	passlog '/n/mail/ctl reads as empty'
} {
	fail '/n/mail/ctl returned data:' $ctlbytes
}

# Empty accounts dir.
acctlist=`{ls /n/mail/accounts >[2] /dev/null}
if {~ $#acctlist 0} {
	passlog 'accounts/ is empty'
} {
	fail 'accounts/ unexpectedly contains' $acctlist
}

# Reject bad ctl verbs.
assert_writefails bogus /n/mail/ctl
assert_writefails 'disconnect ghost' /n/mail/ctl
assert_writefails 'sync ghost' /n/mail/ctl

# `connect` registers the account; bringing it online is a separate,
# best-effort step (see doconnect/tryonline in appl/cmd/mail9p.b). A
# connect to an unresolvable host with no credentials therefore SUCCEEDS:
# the account is registered and left `disconnected`, ready to be brought
# online later via `sync` once credentials/network exist.
assert_writeok 'connect testacct mail.invalid' /n/mail/ctl

# The registered account now appears under /accounts...
acctlist=`{ls /n/mail/accounts >[2] /dev/null}
if {~ $acctlist *testacct} {
	passlog 'accounts/testacct registered after connect (deferred online)'
} {
	fail 'accounts/' $acctlist 'missing testacct after connect'
}

# ...and reads back as disconnected (no live session without credentials).
# (Avoid the variable name `status`; it is reserved in the Inferno shell.)
acctstat=`{cat /n/mail/accounts/testacct/ctl >[2] /dev/null}
if {~ $"acctstat 'disconnected mail.invalid'} {
	passlog 'testacct reads as `disconnected mail.invalid`'
} {
	fail 'testacct ctl unexpected status:' $acctstat
}

# sync on a credential-less account is an accepted no-op (deferred).
assert_writeok 'sync testacct' /n/mail/ctl

# disconnect removes the registered account, returning /accounts to empty.
assert_writeok 'disconnect testacct' /n/mail/ctl
acctlist=`{ls /n/mail/accounts >[2] /dev/null}
if {~ $#acctlist 0} {
	passlog 'accounts/ empty again after disconnect'
} {
	fail 'accounts/' $acctlist 'lingered after disconnect'
}

echo ''
if {~ $failed 0} {
	echo '=== ALL PASS ==='
} {
	echo '=== FAILURES ==='
	raise 'fail: mail9p integration smoke'
}
