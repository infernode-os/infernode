#!/bin/sh
#
# tests/host/link_digest_test.sh
#
# The type digests a module file carries and the loader compares
# (tests/link_digest_test.b says what was wrong), where the Limbo test
# needs more than the suite's emulator gives it:
#
#  - module files whose digest section is missing, cut short, miscounted
#    or changed, made by tests/host/link_digest/mksigs.py, which reads
#    the format with a parser of its own, loaded under -c1 and -c0;
#  - the switch: an emulator made strict by a write to /dev/strictlink
#    (one way: the test's -r, which leaves its emulator strict), and one
#    started strict (emu -L): a module with no digests links in neither;
#  - the two compilers: the test's modules compiled by the native limbo
#    and by /dis/limbo.dis have the same digest section, byte for byte,
#    and limbo -t writes the same table from both.
#
# Skips (exit 77) with no emulator, no python3, or the test not built.
#
. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -x "$LIMBO" ] || { echo "SKIP: no limbo at $LIMBO"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
for f in link_digest_test link_digest_a link_digest_b; do
	[ -f "dis/tests/$f.dis" ] || { echo "SKIP: dis/tests/$f.dis not built"; exit 77; }
done

MK="$ROOT/tests/host/link_digest/mksigs.py"
N=link_digest.$$
D="$ROOT/tmp/$N"		# /tmp/$N inside the emulator
mkdir -p "$D"
trap 'rm -rf "$D"' EXIT

TIMEOUT=${TIMEOUT:-120}
rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

A=dis/tests/link_digest_a.dis
for k in strip noflag nosec trunc over under huge; do
	python3 "$MK" $k $A "$D/$k.dis" || { echo "FAIL: mksigs.py $k"; exit 1; }
done
python3 "$MK" flip $A "$D/flip.dis" plain || { echo "FAIL: mksigs.py flip"; exit 1; }

crashed='SEGV: addr=\|BUS: addr=\|panic:\|Broken:'
for mode in -c1 -c0; do
	# not strict, and then the switch thrown (-r)
	out=$(with_timeout "$TIMEOUT" "$EMU" $mode -r"$ROOT" /dis/sh.dis -c "/dis/tests/link_digest_test.dis -v -d /tmp/$N -r; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- "--- FAIL\|$crashed" &&
	   echo "$out" | grep -q -- "--- PASS: Patched" && echo "$out" | grep -q -- "--- PASS: Ratchet" &&
	   echo "$out" | grep -q "not strict, linked by its 32 bits"; then
		pass "$mode: colliding types refused, mksigs.py's files refused or linked as they should be, the switch set and not cleared"
	else
		fail "$mode, not strict:"
		echo "$out" | grep -v "^===\|--- PASS" | head -30
	fi

	# started strict
	out=$(with_timeout "$TIMEOUT" "$EMU" $mode -L -r"$ROOT" /dis/sh.dis -c "cat /dev/strictlink; echo; /dis/tests/link_digest_test.dis -v -d /tmp/$N; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- "--- FAIL\|$crashed" &&
	   echo "$out" | grep -q "^1$" && echo "$out" | grep -q -- "--- PASS: Patched" &&
	   echo "$out" | grep -q "strict, refused: link typecheck" &&
	   ! echo "$out" | grep -q "not strict, linked"; then
		pass "$mode -L: the same, and a module with no digests is refused"
	else
		fail "$mode -L:"
		echo "$out" | grep -v "^===\|--- PASS" | head -30
	fi
done

# both compilers
hosted=""
for f in link_digest_a link_digest_b link_digest_test; do
	(cd tests && "$LIMBO" -I"$ROOT/module" -o "$D/native_$f.dis" $f.b) || fail "the native limbo did not compile $f.b"
	hosted="$hosted limbo -I /module -o /tmp/$N/hosted_$f.dis $f.b;"
done
(cd libinterp && "$LIMBO" -t Sys -I"$ROOT/module" "$ROOT/module/runt.m" > "$D/native_sys.h") || fail "limbo -t Sys"
out=$(with_timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "cd /tests; $hosted limbo -t Sys -I /module /module/runt.m > /tmp/$N/hosted_sys.h; echo halt > /dev/sysctl" 2>&1 < /dev/null)
ok=1
for f in link_digest_a link_digest_b link_digest_test; do
	if ! python3 "$MK" section "$D/native_$f.dis" "$D/native_$f.sec" || ! [ -s "$D/native_$f.sec" ]; then
		fail "$f.dis from the native limbo has no digest section"; ok=0
	elif ! python3 "$MK" section "$D/hosted_$f.dis" "$D/hosted_$f.sec" 2>/dev/null; then
		fail "$f.dis from /dis/limbo.dis has no digest section: $(echo "$out" | grep -v '^fs:' | head -3)"; ok=0
	elif ! cmp -s "$D/native_$f.sec" "$D/hosted_$f.sec"; then
		fail "$f.dis: the two compilers' digest sections differ"; ok=0
	fi
done
[ $ok = 1 ] && pass "the native limbo and /dis/limbo.dis write the same digest section ($(wc -c < "$D/native_link_digest_test.sec" | tr -d ' ') bytes for the test)"
if [ -s "$D/native_sys.h" ] && grep -q '^Runtab Sysmodtab' "$D/native_sys.h" && cmp -s "$D/native_sys.h" "$D/hosted_sys.h"; then
	pass "limbo -t Sys is the same table, digests and all, from both compilers"
else
	fail "limbo -t Sys differs between the compilers: $(diff "$D/native_sys.h" "$D/hosted_sys.h" 2>&1 | head -4 | cut -c1-200)"
fi
exit $rc
