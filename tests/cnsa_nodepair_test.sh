#!/bin/bash
#
# CNSA 2.0 strict-mode two-node regression test (Gap G1 / INFR-329).
#
# Spins up two SEPARATE emu processes that authenticate over real TCP via the
# native PQ STS handshake (Keyring->auth), and asserts:
#   1. both nodes default            -> ML-KEM-768 handshake succeeds
#   2. both nodes CNSA (CNSAMODE=1)  -> ML-KEM-1024 handshake succeeds
#   3. mixed (1024 listener / 768 dialer) -> handshake FAILS (no silent downgrade)
#
# Requires a built emu and dis/authnode.dis
#   (limbo -gw -Imodule -o dis/authnode.dis tests/authnode.b).
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="$ROOT/emu/MacOSX/o.emu"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"
SIGNER="/tmp/cnsa-signer.$$"
PORT_BASE=19990
fails=0

run() {  # run <envset> <args...> -> writes to $OUT
	local out="$1"; shift
	local cnsa="$1"; shift
	if [ "$cnsa" = "cnsa" ]; then
		( CNSAMODE=1 "$EMU" -r"$ROOT" /dis/authnode.dis "$@" 2>&1 </dev/null ) > "$out" &
	else
		( "$EMU" -r"$ROOT" /dis/authnode.dis "$@" 2>&1 </dev/null ) > "$out" &
	fi
}

pair() {  # pair <name> <listener-mode> <dialer-mode> <expect: OK|FAIL>
	local name="$1" lmode="$2" dmode="$3" expect="$4"
	local port=$((PORT_BASE++))
	pkill -9 -f o.emu 2>/dev/null; sleep 1
	run /tmp/L.$$ "$lmode" listen "tcp!*!$port" "$SIGNER" alice
	sleep 3
	run /tmp/D.$$ "$dmode" dial  "tcp!127.0.0.1!$port" "$SIGNER" bob
	sleep 12; pkill -9 -f o.emu 2>/dev/null
	local lr dr
	lr="$(grep -Eo 'AUTH-OK|AUTH-FAIL' /tmp/L.$$ | head -1)"
	dr="$(grep -Eo 'AUTH-OK|AUTH-FAIL' /tmp/D.$$ | head -1)"
	local want="AUTH-$expect"  # OK -> AUTH-OK, FAIL -> AUTH-FAIL
	if [ "$lr" = "$want" ] && [ "$dr" = "$want" ]; then
		echo "PASS: $name (listener=$lr dialer=$dr)"
	else
		echo "FAIL: $name (want $want; listener=$lr dialer=$dr)"
		fails=$((fails+1))
	fi
	rm -f /tmp/L.$$ /tmp/D.$$
}

pkill -9 -f o.emu 2>/dev/null; sleep 1
( "$EMU" -r"$ROOT" /dis/authnode.dis gen "$SIGNER" 2>&1 </dev/null ) >/dev/null &
sleep 6; pkill -9 -f o.emu 2>/dev/null
[ -s "$ROOT$SIGNER" ] || [ -s "$SIGNER" ] || { echo "FAIL: signer not generated"; exit 1; }

pair "both-default-768"   plain plain OK
pair "both-cnsa-1024"     cnsa  cnsa  OK
pair "mixed-1024-vs-768"  cnsa  plain FAIL

rm -f "$ROOT$SIGNER" "$SIGNER" 2>/dev/null
echo "----"
if [ "$fails" -eq 0 ]; then echo "CNSA two-node: ALL PASS"; exit 0; else echo "CNSA two-node: $fails FAILED"; exit 1; fi
