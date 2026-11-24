#!/bin/sh
#
# tests/host/login_test.sh
#
# login(6), version 3, from outside the tree's own code.
#
# The exchange stands on three things that the Limbo test
# (tests/login_test.b) can only take as given: that the groups it holds
# are RFC 3526's and safe primes, that the key derivation is the one the
# manual page describes, and that both hold under the interpreter and
# the JIT alike.  This checks them:
#
#   - tests/host/login/mkgroups.py makes groups 14, 15 and 16 from RFC
#     3526's formulas (pi, by Machin's series), checks each is a safe
#     prime with 2 of order q and the top 64 bits ones, and compares
#     them with the constants in appl/lib/login.b and tests/login_test.b;
#   - tests/host/login/mkvectors.py computes the masked value, the masked ML-KEM seed, the two
#     proofs and the session secret with Python's cryptography, from
#     the page and none of the tree's code, and every value it prints
#     must be in tests/login_test.b (testVectors compares them with the
#     tree's);
#   - tests/login_test.b runs under -c0 and -c1.
#
# Skips (exit 77) without python3; the vectors' half is left out
# without Python's cryptography, and the emulator's without an emulator.
#
. "$(dirname "$0")/common.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
D="$ROOT/tests/host/login"
rc=0

if out=$(python3 "$D/mkgroups.py" -c "$ROOT/appl/lib/login.b" "$ROOT/tests/login_test.b" 2>&1); then
	echo "PASS: the groups are RFC 3526's 14, 15 and 16, safe primes"
else
	echo "FAIL: the groups:"
	echo "$out"
	rc=1
fi

if python3 -c 'import cryptography' 2>/dev/null; then
	missing=$(python3 "$D/mkvectors.py" | sed -n 's/.*: \([0-9a-f]\{32,\}\)$/\1/p' | while read v; do
		grep -q "\"$v\"" "$ROOT/tests/login_test.b" || echo "$v"
	done)
	n=$(python3 "$D/mkvectors.py" | grep -c ': [0-9a-f]\{32,\}$')
	if [ "$n" = 13 ] && [ -z "$missing" ]; then
		echo "PASS: the key derivation's known answers in tests/login_test.b are Python's"
	else
		echo "FAIL: known answers not in tests/login_test.b ($n made):"
		echo "$missing"
		rc=1
	fi
else
	echo "SKIP: no Python cryptography: the known answers not made again"
fi

if [ -x "$EMU" ] && [ -f "$ROOT/dis/tests/login_test.dis" ]; then
	mkdir -p "$ROOT/tmp"
	for c in 0 1; do
		out=$(with_timeout "${TIMEOUT:-240}" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/login_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
		if echo "$out" | grep -q "^PASS$" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|BUS: addr=\|panic:\|Broken'; then
			echo "PASS: login_test under -c$c"
		else
			echo "FAIL: login_test under -c$c:"
			echo "$out" | grep -v '^logind:' | head -30
			rc=1
		fi
	done
else
	echo "SKIP: no emulator or dis/tests/login_test.dis: login_test not run"
fi
exit $rc
