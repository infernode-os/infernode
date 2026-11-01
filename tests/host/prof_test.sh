#!/bin/sh
#
# prof_test.sh -- the profiler, from prof(1) to the device and back.
#
# prof(1) binds the profiling device on /prof (appl/lib/profile.b) and
# had not worked in this tree: the emulators' root had no /prof to bind
# on, which upstream Inferno's has ("cannot bind prof device to /prof:
# '/prof' file does not exist"). And the device was #P, which on a native
# kernel is arch: a bind there succeeded onto the wrong device. It is #K
# now, kprof's letter in Plan 9, 9front and Inferno's native kernels
# (docs/DEVICE-LETTERS.md), and #P is arch everywhere.
#
ROOT="${ROOT:-.}"
. "$(dirname "$0")/common.sh"

if [ ! -x "$EMU" ]; then
	echo "SKIP: emu not found at $EMU"
	exit 0
fi

PASSED=0; FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

out=$(timeout 240 "$EMU" -r"$ROOT" -c0 sh -c "ls '#K'; ls -d /prof; ls '#P' >[2=1]; prof -e sh -c 'load std; for(i in \`{seq 1 30000}) { x=\$i }' >[2=1]" < /dev/null 2>&1)

echo "$out" | grep -q '^#K/ctl$' && pass "#K is the profiling device" || fail "#K: $(echo "$out" | head -2 | tr '\n' ' ')"
echo "$out" | grep -q '^/prof$' && pass "/prof is in the emulator's root, for prof(1) to bind on" || fail "no /prof"
echo "$out" | grep -q 'stat #P: unknown device' && pass "#P is not the profiler in the emulator (it is arch, on a board)" || fail "#P: $(echo "$out" | grep '#P' | head -1)"
if echo "$out" | grep -q '^Module: Sh(/dis/sh.dis)' && echo "$out" | grep -q 'module sampling points [1-9]'; then
	pass "prof -e samples a running module (sh)"
else
	fail "prof: $(echo "$out" | grep -E 'prof:|Module' | head -2 | tr '\n' ' ')"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED  Skipped: 0"
[ $FAILED -eq 0 ]
