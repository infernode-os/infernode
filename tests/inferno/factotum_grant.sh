#!/dis/sh.dis
# Regression/security test for INFR-363: a child gets /mnt/factotum (and can read
# its key) ONLY if it holds a credentialed tool (websearch). Uses a DUMMY key.
load std
path=(/dis .)
mount -ac {mntgen} /n
bind -a '#I' /net
ndb/cs
auth/factotum >[2] /dev/null
echo 'key proto=pass service=brave user=apikey !password=DUMMYBRAVEKEY01' > /mnt/factotum/ctl >[2] /dev/null
echo '--- websearch granted: expect VISIBLE + keylen=15 ---'
/tests/factotum_grant_test.dis with
echo '--- vision granted: expect VISIBLE + keylen=15 ---'
/tests/factotum_grant_test.dis vision
echo '--- no websearch: expect HIDDEN ---'
/tests/factotum_grant_test.dis without
echo '--- websearch plus exec: expect HIDDEN ---'
/tests/factotum_grant_test.dis withexec
echo FACGRANT DONE
