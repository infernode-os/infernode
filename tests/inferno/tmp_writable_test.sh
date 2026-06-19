#!/dis/sh.dis
# Test that /tmp is writable
#
# This verifies that /tmp is not shadowed by a read-only root device entry.
# The profile should bind $home/tmp to /tmp, making it writable.
#

load std

echo '=== /tmp Writable Test ==='
echo ''

# Test 1: Check /tmp exists
echo '=== Test 1: Check /tmp exists ==='
if {! ftest -d /tmp} {
	echo 'FAIL: /tmp does not exist'
	raise 'fail:/tmp does not exist'
}
echo 'PASS: /tmp exists'
echo ''

# Test 2: Create a file in /tmp
echo '=== Test 2: Create file in /tmp ==='
testfile=/tmp/writable_test_tmpcheck
echo 'test data' > $testfile
if {! ftest -f $testfile} {
	echo 'FAIL: Cannot create file in /tmp'
	echo 'This may indicate /tmp is in read-only root device'
	raise 'fail:cannot write to /tmp'
}
echo 'PASS: Created' $testfile
echo ''

# Test 3: Read the file back
echo '=== Test 3: Read file back ==='
cat $testfile >/dev/null
if {! ftest -s $testfile} {
	echo 'FAIL: File is empty or unreadable'
	rm $testfile >[2] /dev/null
	raise 'fail:file unreadable'
}
echo 'PASS: File readable and non-empty'
echo ''

# Test 4: Delete the file
echo '=== Test 4: Delete file ==='
rm $testfile
if {ftest -f $testfile} {
	echo 'FAIL: Cannot delete file from /tmp'
	raise 'fail:cannot delete from /tmp'
}
echo 'PASS: File deleted'
echo ''

echo '=== All Tests Passed ==='
