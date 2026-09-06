#!/bin/sh
#
# tests/host/wpa_vectors_test.sh
#
# The WPA2 supplicant's cryptography against its published test
# vectors, as a named CI step rather than one line in a long suite.
#
# tests/wpa_test.b is an ordinary Limbo test and the runner finds it on
# its own, but what it checks is the difference between a machine that
# joins a home network and one that silently cannot: PBKDF2-HMAC-SHA1
# (RFC 6070), the passphrase-to-PSK mapping and the PRF (IEEE 802.11i
# Annex H), AES key unwrap (RFC 3394), AES-CMAC (RFC 4493), and whole
# four-way handshakes at key descriptor versions 2 and 3 driven from
# synthetic frames.  A failure there is not a flaky test,
# it is a supplicant that will never authenticate, and it should be
# legible in the job list without reading a suite summary.
#
# No radio and no board: every one of those is arithmetic, and this is
# the only part of the WiFi work a build machine can prove at all.
#
# Skips (exit 77) when there is no emulator to run it in.
#
# Run from project root: ./tests/host/wpa_vectors_test.sh
#

. "$(dirname "$0")/common.sh"

TEST=dis/tests/wpa_test.dis

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/$TEST" ] || { echo "SKIP: $TEST not built"; exit 77; }

out=$("$EMU" -c1 -r"$ROOT" "/$TEST" 2>&1)
rc=$?

echo "$out"

if [ "$rc" -ne 0 ]; then
	echo "FAIL: wpa_test exited $rc"
	exit 1
fi

# The runner prints PASS only when every case passed; a crash before
# the summary would leave rc 0 on some paths, so require the word.
if ! echo "$out" | grep -q '^PASS$'; then
	echo "FAIL: wpa_test did not report PASS"
	exit 1
fi

# And require that the cases actually ran, so an empty or truncated run
# cannot be mistaken for a green one.
for c in Pbkdf2 Psk Prf Keyunwrap Cmac Micversions Handshake HandshakeV3 Unknownversion Ignored; do
	if ! echo "$out" | grep -q "^--- PASS: $c"; then
		echo "FAIL: $c did not run"
		exit 1
	fi
done

echo "PASS: WPA2 key derivation and handshake match their published vectors"
exit 0
