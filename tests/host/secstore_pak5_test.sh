#!/bin/sh
#
# tests/host/secstore_pak5_test.sh
#
# secstore version 5's key derivation (secstore(2)'s PAK5) from outside
# the tree's own code: tests/host/secstore/pak5vectors.py computes the
# masked ML-KEM seed, both proofs and the session's secret with
# Python's hashlib and cryptography from the description in
# appl/lib/secstore.b, and every value it prints must be in
# tests/secstore_crypto_test.b, whose Pak5Vectors compares them with
# the tree's (and runs here under -c0 and -c1).
#
# Skips (exit 77) without python3 or Python's cryptography; the
# emulator's half is left out without an emulator.
#
. "$(dirname "$0")/common.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
python3 -c 'import cryptography' 2>/dev/null || { echo "SKIP: no Python cryptography"; exit 77; }
rc=0

out=$(python3 "$ROOT/tests/host/secstore/pak5vectors.py")
n=$(echo "$out" | grep -c ': [0-9a-f]\{64,\}$')
missing=$(echo "$out" | sed -n 's/.*: \([0-9a-f]\{64,\}\)$/\1/p' | while read v; do
	grep -q "\"$v\"" "$ROOT/tests/secstore_crypto_test.b" || echo "$v"
done)
if [ "$n" = 7 ] && [ -z "$missing" ]; then
	echo "PASS: version 5's known answers in tests/secstore_crypto_test.b are Python's"
else
	echo "FAIL: known answers not in tests/secstore_crypto_test.b ($n made):"
	echo "$missing"
	rc=1
fi

if [ -x "$EMU" ] && [ -f "$ROOT/dis/tests/secstore_crypto_test.dis" ]; then
	for c in 0 1; do
		out=$(with_timeout "${TIMEOUT:-240}" "$EMU" -c$c -r"$ROOT" /dis/sh.dis -c "/dis/tests/secstore_crypto_test.dis; echo halt > /dev/sysctl" 2>&1 < /dev/null)
		if echo "$out" | grep -q -- "--- PASS: Pak5Vectors" && ! echo "$out" | grep -q -- '--- FAIL\|SEGV: addr=\|panic:\|Broken'; then
			echo "PASS: secstore_crypto_test under -c$c"
		else
			echo "FAIL: secstore_crypto_test under -c$c:"
			echo "$out" | head -30
			rc=1
		fi
	done
else
	echo "SKIP: no emulator or dis/tests/secstore_crypto_test.dis: not run"
fi
exit $rc
