#!/dis/sh.dis
#
# Regression test for emu Sys_pctl(NEWFD|NEWNS) deadlock against Limbo-served
# mounts (trfs / mntgen / any 9P file server).
#
# See docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md
#
# History: commit 89db5178 ("fix(ns): close formal-verification race windows")
# added a premature acquire() of the VM lock before the NEWNS branch in
# Sys_pctl. cclone(dot) inside NEWNS then ran with the VM lock held, blocking
# on 9P walks into Limbo-implemented file servers that need the VM lock to
# answer. Every Styxserver.new on a CWD under /n/local (trfs) wedged. Lucifer
# couldn't start.
#
# This test catches that class of bug by exercising the exact pattern:
#   1. Confirm trfs has mounted /n/local (so the namespace is Limbo-served).
#   2. cd into /n/local so CWD is on trfs.
#   3. Spawn a stock 9P server (tools9p) — Styxserver.new internally calls
#      pctl(NEWFD|NEWNS, fd::nil).
#   4. Poll for its mountpoint to appear within 5 seconds.
#
# If pctl(NEWNS) deadlocks, the mountpoint never appears and the test fails
# on timeout. A working emu shows the mountpoint within ~1 second.

load std

echo '=========================================='
echo 'NEWNS-after-trfs deadlock regression test'
echo '=========================================='

failed=0

echo ''
echo 'Step 1: confirm trfs is mounted at /n/local'
if {! ftest -d /n/local} {
	echo 'SKIP: /n/local not mounted (trfs unavailable in this profile)'
	exit 0
}
echo 'PASS: /n/local present'

echo ''
echo 'Step 2: cd into trfs-backed namespace (CWD must be on Limbo server)'
cd /n/local
echo 'PASS: cd /n/local'

echo ''
echo 'Step 3: spawn a Styxserver-using 9P FS (tools9p) — exercises pctl(NEWNS)'
# Run in background. tools9p will call Styxserver.new which calls
# pctl(NEWFD|NEWNS, fd::nil) inside its tmsgreader spawn.
/dis/veltro/tools9p -v -m /tmp/newns-test-tool -b read >[2]/tmp/newns-test.log &
toolspid=$apid

echo 'spawned tools9p as pid' $toolspid

echo ''
echo 'Step 4: poll /tmp/newns-test-tool for up to 5s'
mounted=0
for i in 1 2 3 4 5 {
	sleep 1
	if {ftest -d /tmp/newns-test-tool} {
		mounted=1
		echo 'PASS: tools9p mounted after' $i 's'
		break
	}
	echo '... still waiting (' $i 's elapsed)'
}

if {~ $mounted 0} {
	echo 'FAIL: tools9p did not mount within 5s — pctl(NEWFD|NEWNS) likely deadlocked'
	echo 'See docs/postmortems/2026-05-17-newns-vm-lock-deadlock.md'
	failed=1
}

echo ''
echo 'Step 5: cleanup'
unmount /tmp/newns-test-tool >[2]/dev/null
kill $toolspid >[2]/dev/null

echo ''
if {~ $failed 0} {
	echo '=========================================='
	echo 'NEWNS-after-trfs: PASS'
	echo '=========================================='
	exit 0
}{
	echo '=========================================='
	echo 'NEWNS-after-trfs: FAIL'
	echo '=========================================='
	raise 'fail:newns-deadlock-regression'
}
