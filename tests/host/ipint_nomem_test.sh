#!/bin/sh
# IPint where the old code ended the emulator or lost the kernel's
# memory, in an emulator of its own with a small main pool
# (tests/ipint_nomem.b fills it).
#
# A long IPint operation (a product, a quotient, a power) copies its
# operands and makes its result with the VM let go, and libmp raises
# when there is no memory for what it is asked. The raise left through
# the builtin, and the copies and the result were lost with it: one
# product of two 60MB numbers left 250MB of the kernel's pool held by
# nothing, and three such calls left the kernel without memory, for
# every program, until the emulator was started again.
#
# - mul, div, mod and expmod of a 5MB number, nine times each with 8MB
#   of the main pool free in one piece: the copy fits and the result or
#   libmp's working number does not; every call raises and the main
#   pool is where it was afterwards (5MB a round stayed lost)
# - strtoip in base 32 of a length base 32 does not have is nil (the
#   decoder's -1 was a count of bytes to betomp, which read 4GB and wrote
#   backwards through the main pool: the emulator ended, or went on
#   with the pool written over)
# - bytestoip of 2^28-4, 2^28+1 and 2^29+1 bytes is refused (the first
#   made the longest number libmp counts, which plus one or times three
#   was stored past a hundred-byte block; the others were stored from
#   the first digit, or before it)
# - with room again a product, a quotient and a power are right

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "ipint_nomem_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/ipint_nomem.dis ] || { echo "ipint_nomem_test: SKIP (dis/tests/ipint_nomem.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

for mode in -c1 -c0; do
	out=$(with_timeout 300 "$EMU" $mode -pheap=1024m -pmain=96m -r"$ROOT" /dis/tests/ipint_nomem.dis 2>&1 < /dev/null)
	ok=1
	echo "$out" | grep -q '^DONE$' || { fail "$mode: the program did not finish: $(echo "$out" | grep -v '^pool \|^fs:\|^	' | tail -3 | tr '\n' ' ' | cut -c1-300)"; ok=0; }
	echo "$out" | grep -q '^B32 6 of 6 nil$' || { fail "$mode: base 32 of a length it does not have: $(echo "$out" | grep '^B32' | tr '\n' ' ')"; ok=0; }
	echo "$out" | grep -q '^BYTES 3 of 3 refused$' || { fail "$mode: bytes whose bits pass an int: $(echo "$out" | grep '^BYTES' | tr '\n' ' ')"; ok=0; }
	for op in mul div mod expmod; do
		line=$(echo "$out" | grep "^LOST $op ")
		lost=$(echo "$line" | awk '{print $3}')
		raised=$(echo "$line" | awk '{print $5}')
		if [ "$raised" != 9 ]; then
			fail "$mode: $op with no room for its result raised ${raised:-?} times of 9"
			ok=0
		elif [ -z "$lost" ] || [ "$lost" -gt 1048576 ]; then
			fail "$mode: nine refused ${op}s kept ${lost:-?} bytes of the main pool"
			ok=0
		fi
	done
	echo "$out" | grep -q '^ROOM 1 1 1$' || { fail "$mode: with room again: $(echo "$out" | grep '^ROOM')"; ok=0; }
	[ $ok = 1 ] && pass "$mode: refused products, quotients and powers leave the main pool where it was ($(echo "$out" | grep '^LOST' | awk '{printf "%s %s ", $2, $3}')); base 32 and long bytes refused"
done
exit $rc
