load std

root=/tmp/brick-ft-test
mkdir -p /mnt/factotum $root/failbrick/config $root/failprofile
auth/factotum
sleep 1
echo 3333333333333333333333333333333333333333333333333333333333333333 > $root/failbrick/config/spki
echo 'pub 4444444444444444444444444444444444444444444444444444444444444444' > $root/failbrick/config/sdg
echo D2-UNCHANGED > $root/failbrick/config/d2
echo PEER-UNCHANGED > $root/failbrick/config/peer
if {brick pair -d $root/failprofile $root/failbrick} {
	echo BAD-PAIR-SUCCEEDED
} {
	echo PAIR-PERSISTENCE-REFUSED
}
if {ftest -e $root/failprofile/pair.lock} {echo BAD-FAIL-PAIR-LOCK} {echo NO-FAIL-PAIR-LOCK}
echo PEER `{cat $root/failbrick/config/peer}
echo SDG `{cat $root/failbrick/config/sdg}
echo D2 `{cat $root/failbrick/config/d2}
echo FACTOTUM-FAIL-DONE
echo halt > '#c/sysctl'
