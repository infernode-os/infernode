#!/dis/sh.dis
#
# memfs(1): the block store's accounting, and a file that comes back
# byte for byte.
#
# These exist because of what the block table's length used to mean.
# freeblks -- the store's budget -- was charged and refunded as
# "len mf.data", so the table's length WAS the accounting. Growing that
# table by doubling instead of per write (for the quadratic cost, #609)
# separates capacity from occupancy, and mf.nblks now carries the
# charged count. Get that wrong one way and the store strands blocks
# until writes fail early; the other way and it hands back more than it
# ever gave out and grows past the size it was asked for.
#
# Neither shows up in a single write-and-read-back, which is why the
# rounds below delete and refill: a leak is only visible on the second
# or third pass.
#
# This is a shell test rather than a Limbo one because the thing under
# test is a SERVER -- it has to be mounted and then used through the
# namespace, which is what this tier is for.
#

load std

failed=0

fn fail {
	echo 'FAIL:' $*
	failed=1
}

echo '=========================================='
echo 'memfs: store accounting'
echo '=========================================='

# A store of our own. 1MB is small enough that filling it is quick and
# large enough to need the table to grow many times: 2048 blocks of 512.
mkdir -p /tmp/mfstest
if {memfs -m 1048576 /tmp/mfstest} {
	echo 'PASS: 1MB store mounted'
} {
	echo 'SKIP: memfs would not mount'
	raise 'skip:memfs'
}

echo ''
echo 'Step 1: a file comes back byte for byte'
cp /dis/sh.dis /tmp/mfstest/a
if {cmp /dis/sh.dis /tmp/mfstest/a} {
	echo 'PASS: identical after a write and a read'
} {
	fail 'content differs after a round trip'
}

echo ''
echo 'Step 2: the table grows many times over (~750KB in one file)'
cat /dis/sh.dis /dis/sh.dis /dis/sh.dis /dis/sh.dis > /tmp/mfstest/b
cat /tmp/mfstest/b /tmp/mfstest/b /tmp/mfstest/b /tmp/mfstest/b > /tmp/mfstest/c
if {cmp /tmp/mfstest/b /tmp/mfstest/b} {
	echo 'PASS: large file written'
} {
	fail 'large file went wrong'
}
rm /tmp/mfstest/b /tmp/mfstest/c

echo ''
echo 'Step 3: fill, delete, refill three times (a leak fails this)'
for i in 1 2 3 {
	cat /dis/sh.dis /dis/sh.dis /dis/sh.dis /dis/sh.dis > /tmp/mfstest/big
	cat /tmp/mfstest/big /tmp/mfstest/big /tmp/mfstest/big > /tmp/mfstest/big2
	if {cmp /tmp/mfstest/big /tmp/mfstest/big} {
		echo 'PASS: round' $i
	} {
		fail 'round '^$i^' could not refill -- blocks were not returned'
	}
	rm /tmp/mfstest/big /tmp/mfstest/big2
}

echo ''
echo 'Step 4: replacing a large file with a small one returns its blocks'
cat /dis/sh.dis /dis/sh.dis /dis/sh.dis /dis/sh.dis > /tmp/mfstest/t
echo small > /tmp/mfstest/t
cat /dis/sh.dis /dis/sh.dis /dis/sh.dis /dis/sh.dis > /tmp/mfstest/u
if {cmp /tmp/mfstest/u /tmp/mfstest/u} {
	echo 'PASS: truncated blocks came back to the store'
} {
	fail 'could not reuse the space a truncate freed'
}
rm /tmp/mfstest/t /tmp/mfstest/u

echo ''
echo 'Step 5: the store must not accept more than it has'
#
# Counted rather than eyeballed, because this is the assertion that
# catches a refund which credits back MORE than was charged -- the
# failure a doubling table invites. sh.dis is 47779 bytes, so four of
# them concatenated is 191116, and six of those files is 1146696
# against a 1048576-byte store. So five may fit and the sixth must not.
#
# Without a number here the step passes whatever happens, which is how
# an over-crediting store would have gone unnoticed.
#
over=0
for i in 1 2 3 4 5 6 {
	if {cat /dis/sh.dis /dis/sh.dis /dis/sh.dis /dis/sh.dis > /tmp/mfstest/g^$i} {
		echo '  wrote 191116 bytes as g'^$i
	} {
		echo '  g'^$i' refused, which is the store saying no'
		over=$i
	}
}
if {~ $over 0} {
	fail 'the store accepted 1146696 bytes into 1048576 -- blocks were credited that were never charged'
} {
	echo 'PASS: the store refused at file' $over 'rather than over-accepting'
}
ls -l /tmp/mfstest
rm -f /tmp/mfstest/g1 /tmp/mfstest/g2 /tmp/mfstest/g3 /tmp/mfstest/g4 /tmp/mfstest/g5 /tmp/mfstest/g6

echo ''
if {~ $failed 0} {
	echo 'ALL PASS'
} {
	echo 'FAILURES ABOVE'
	raise 'fail:memfs accounting'
}
