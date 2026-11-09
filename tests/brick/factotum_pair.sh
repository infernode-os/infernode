load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum $root/brick/config $root/profile
auth/factotum -f $root/factotum.keys -p testpass
sleep 1
echo 1111111111111111111111111111111111111111111111111111111111111111 > $root/brick/config/spki
echo 'pub 2222222222222222222222222222222222222222222222222222222222222222' > $root/brick/config/sdg
echo initial > $root/brick/config/d2
echo initial > $root/brick/config/peer
brick pair -d $root/profile $root/brick
echo FIRST-PIN
brick key -d $root/profile
echo FACTOTUM-KEYS
cat /mnt/factotum/ctl
if {ftest -e $root/profile/client.key} {echo BAD-CLIENT-KEY-FILE} {echo NO-CLIENT-KEY-FILE}
if {ftest -e $root/profile/sdg.key} {echo BAD-SDG-KEY-FILE} {echo NO-SDG-KEY-FILE}
if {ftest -e $root/profile/sdg.psk} {echo BAD-SDG-PSK-FILE} {echo NO-SDG-PSK-FILE}
if {ftest -e $root/profile/d2.key} {echo BAD-D2-KEY-FILE} {echo NO-D2-KEY-FILE}
# A real config/sdg read always reports the brick public key.  Restore that
# status shape in this regular-file fake before exercising an idempotent retry.
echo 'pub 2222222222222222222222222222222222222222222222222222222222222222' > $root/brick/config/sdg
brick pair -d $root/profile $root/brick
echo RETRY-PIN
brick key -d $root/profile
if {ftest -e $root/profile/pair.lock} {echo BAD-PAIR-LOCK} {echo NO-PAIR-LOCK}
echo FACTOTUM-PAIR-DONE
echo halt > '#c/sysctl'
