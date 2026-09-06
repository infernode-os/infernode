#!/bin/sh
#
# tests/host/dhcp_client_test.sh
#
# The DHCP client, as a named CI step rather than one line in a long
# suite: appl/lib/dhcpclient.b against a synthetic server, and ip/dhcp
# against the module it loads.
#
# tests/dhcp_test.b is an ordinary Limbo test and the runner finds it on
# its own, but what it checks is the difference between a machine that
# has an address and one that has a working, authenticated, frame-
# passing link and no IP configuration on it -- which is exactly where
# the bare-metal port stood before this client existed. A failure there
# is not a flaky test, it is a machine that cannot be reached.
#
# The exchange runs against a UDP conversation the test serves itself
# (memfs + file2chan), not against a real server: binding port 68 needs
# privilege, so a hosted emu running as an ordinary user cannot put the
# client on a real socket at all. What this proves is the wire format,
# the option encoding and decoding, and the state machine. Whether a
# server on a network agrees is a question only a board can answer.
#
# Skips (exit 77) when there is no emulator to run it in.
#
# Run from project root: ./tests/host/dhcp_client_test.sh
#

. "$(dirname "$0")/common.sh"

TEST=dis/tests/dhcp_test.dis
CLIENT=dis/lib/dhcpclient.dis
CMD=dis/ip/dhcp.dis

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/$TEST" ] || { echo "SKIP: $TEST not built"; exit 77; }

# The library must exist where module/dhcp.m says it does, because that
# is the only path ip/dhcp will ever look in.
if [ ! -f "$ROOT/$CLIENT" ]; then
	echo "FAIL: $CLIENT is missing; module/dhcp.m declares that path"
	exit 1
fi

out=$("$EMU" -c1 -r"$ROOT" "/$TEST" 2>&1)
rc=$?

echo "$out"

if [ "$rc" -ne 0 ]; then
	echo "FAIL: dhcp_test exited $rc"
	exit 1
fi

if ! echo "$out" | grep -q '^PASS$'; then
	echo "FAIL: dhcp_test did not report PASS"
	exit 1
fi

# Require that the cases actually ran, so an empty or truncated run
# cannot be mistaken for a green one.
for c in Options Exchange; do
	if ! echo "$out" | grep -q "^--- PASS: $c"; then
		echo "FAIL: $c did not run"
		exit 1
	fi
done

#
# And the command that was the reason for all of this. ip/dhcp on a
# directory that is not an interface must fail on the directory, not on
# the module: "module not loaded" is the symptom this work existed to
# remove, and a rename or a missing manifest entry would bring it back
# without any Limbo test noticing.
#
if [ -f "$ROOT/$CMD" ]; then
	cmdout=$("$EMU" -c1 -r"$ROOT" "/$CMD" /net/ipifc/999 2>&1)
	echo "$cmdout"
	if echo "$cmdout" | grep -q 'module not loaded'; then
		echo "FAIL: ip/dhcp still cannot load $CLIENT"
		exit 1
	fi
	if ! echo "$cmdout" | grep -q '^dhcp: cannot open'; then
		echo "FAIL: ip/dhcp did not report the missing interface it was given"
		exit 1
	fi
else
	echo "note: $CMD not built; skipped the ip/dhcp load check"
fi

echo "PASS: the DHCP client completes a DISCOVER/OFFER/REQUEST/ACK exchange"
exit 0
