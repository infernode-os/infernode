#!/dis/sh.dis
# Regression/security test for INFR-363: a child gets /mnt/factotum (and can read
# its key) ONLY if it holds a credentialed tool (websearch). Uses a DUMMY key.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
# A factotum service of its own: #sfactotum is one for the whole emulator,
# and another test's factotum may still hold it.
auth/factotum -s factotum.^${pid} >[2] /dev/null
echo 'key proto=pass service=brave user=apikey !password=DUMMYBRAVEKEY01' > /mnt/factotum/ctl >[2] /dev/null
failed=()
# websearch or vision granted: the key VISIBLE (keylen=15); with no
# credentialed tool, or with exec beside it: HIDDEN
for mode in with vision without withexec {
	if {! /tests/factotum_grant_test.dis $mode} {failed=($failed $mode)}
}
if {! ~ $#failed 0} {raise 'fail:factotum_grant: '^$"failed}
echo FACGRANT DONE
