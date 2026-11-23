#!/bin/sh
# CNSA 2.0 mode and the key file a connection is authenticated with
# (tests/cnsa_auth_test.b), in an emulator started in the mode and in
# one that is not.
#
# The emulator's own switch (CNSAMODE in the host's environment, read
# once) is what Keyring's auth goes by, so a test of its rule needs an
# emulator of its own.  In the mode it took whatever key file it was
# given, an Ed25519 one over a 2048-bit group among them, and signed the
# exchange over SHA-256; auth(2) asked nothing of a key file either.
#
# In the mode: Ed25519 key files, a 2048-bit group and a certificate
# over SHA-256 are refused by Keyring's auth, each end told why, and
# the mode's key files authenticate and agree a secret; auth(2) refuses
# the same before a byte is sent.  Out of it: Ed25519 key files
# authenticate, and auth(2) still refuses by the environment's
# /env/cnsamode.  Under -c1 and -c0.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "cnsa_auth_test: SKIP (no emu)"; exit 77; }
[ -f dis/tests/cnsa_auth_test.dis ] || { echo "cnsa_auth_test: SKIP (dis/tests/cnsa_auth_test.dis not built)"; exit 77; }

rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

for mode in -c1 -c0; do
	out=$(with_timeout 120 env CNSAMODE=1 "$EMU" $mode -r"$ROOT" /dis/sh.dis -c "/tests/cnsa_auth_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q '^2 passed$' && echo "$out" | grep -q -e '--- PASS: Keyring'; then
		pass "$mode, CNSAMODE=1: Keyring's auth and auth(2) take only the mode's key files"
	else
		fail "$mode, CNSAMODE=1: $(echo "$out" | grep -v '^fs:' | grep -e 'FAIL\|SKIP\|Keyring:\|AuthLib:\|passed' | tr '\n' ' ' | cut -c1-600)"
	fi
	out=$(with_timeout 120 env -u CNSAMODE "$EMU" $mode -r"$ROOT" /dis/sh.dis -c "/tests/cnsa_auth_test.dis -v; echo halt > /dev/sysctl" 2>&1 < /dev/null)
	if echo "$out" | grep -q '^1 passed, 1 skipped$' && echo "$out" | grep -q -e '--- PASS: AuthLib'; then
		pass "$mode, not in the mode: Ed25519 key files authenticate; auth(2) goes by /env/cnsamode"
	else
		fail "$mode, not in the mode: $(echo "$out" | grep -v '^fs:' | grep -e 'FAIL\|Keyring:\|AuthLib:\|passed' | tr '\n' ' ' | cut -c1-600)"
	fi
done
exit $rc
