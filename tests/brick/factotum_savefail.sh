load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum $root/savebrick/config $root/saveprofile
# The missing parent makes the encrypted keyfile's temporary create fail.
# Factotum may start empty, but sync must return that persistence error.
auth/factotum -f $root/no/such/factotum.keys -p testpass
sleep 1
echo 3333333333333333333333333333333333333333333333333333333333333333 > $root/savebrick/config/spki
echo 'pub 4444444444444444444444444444444444444444444444444444444444444444' > $root/savebrick/config/sdg
echo D2-UNCHANGED > $root/savebrick/config/d2
echo PEER-UNCHANGED > $root/savebrick/config/peer
if {brick pair -d $root/saveprofile $root/savebrick} {
	echo BAD-SAVE-PAIR-SUCCEEDED
} {
	echo PAIR-SAVE-REFUSED
}
if {ftest -e $root/saveprofile/pair.lock} {echo BAD-SAVE-PAIR-LOCK} {echo NO-SAVE-PAIR-LOCK}
echo SAVE-PEER `{cat $root/savebrick/config/peer}
echo SAVE-SDG `{cat $root/savebrick/config/sdg}
echo SAVE-D2 `{cat $root/savebrick/config/d2}
echo FACTOTUM-SAVEFAIL-DONE
echo halt > '#c/sysctl'
