#!/bin/bash
#
# CNSA 2.0 strict-mode two-node regression test (Gap G1 / INFR-329).
#
# Spins up two SEPARATE emu processes that authenticate over real TCP via the
# native PQ STS handshake (Keyring->auth), and asserts:
#   1. both nodes default                  -> ML-KEM-768 handshake succeeds
#   2. both nodes CNSA, ed25519 signer     -> ML-KEM-1024 handshake succeeds
#   3. both nodes CNSA, ML-DSA-87 signer   -> ML-KEM-1024 + CNSA signer succeeds
#   4. mixed 1024 listener / 768 dialer    -> handshake FAILS (no silent downgrade)
#
# Requires a built emu and dis/authnode.dis
#   (limbo -gw -Imodule -o dis/authnode.dis tests/authnode.b).
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"

TMPHOST="${TMPDIR:-/tmp}/cnsa-nodepair.$$"
SIGNER_ED="/tmp/cnsa-signer-ed.$$"
SIGNER_ML="/tmp/cnsa-signer-mldsa87.$$"
PORT_BASE=19990
fails=0
pids=""

mkdir -p "$TMPHOST" || { echo "FAIL: cannot create $TMPHOST"; exit 1; }
mkdir -p "$ROOT/tmp" || { echo "FAIL: cannot create $ROOT/tmp"; exit 1; }

cleanup()
{
	for pid in $pids; do
		kill "$pid" 2>/dev/null
	done
	wait 2>/dev/null
	rm -rf "$TMPHOST"
	rm -f "$ROOT$SIGNER_ED" "$ROOT$SIGNER_ML" "$SIGNER_ED" "$SIGNER_ML" 2>/dev/null
}
trap cleanup EXIT INT TERM

start_node() {  # start_node <out> <mode: plain|cnsa> <args...> -> prints pid
	local out="$1"; shift
	local mode="$1"; shift
	if [ "$mode" = "cnsa" ]; then
		( CNSAMODE=1 "$EMU" -r"$ROOT" /dis/authnode.dis "$@" 2>&1 </dev/null ) > "$out" &
	else
		( "$EMU" -r"$ROOT" /dis/authnode.dis "$@" 2>&1 </dev/null ) > "$out" &
	fi
	local pid=$!
	pids="$pids $pid"
	echo "$pid"
}

wait_for_pattern() {  # wait_for_pattern <file> <regex> <seconds>
	local file="$1" pattern="$2" limit="$3"
	local i=0
	while [ "$i" -lt "$limit" ]; do
		if grep -Eq "$pattern" "$file" 2>/dev/null; then
			return 0
		fi
		sleep 1
		i=$((i+1))
	done
	return 1
}

wait_pid() {  # wait_pid <pid> <seconds>
	local pid="$1" limit="$2"
	local i=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$i" -ge "$limit" ]; then
			return 1
		fi
		sleep 1
		i=$((i+1))
	done
	wait "$pid" 2>/dev/null
	return 0
}

make_signer() {  # make_signer <path> <alg>
	local path="$1" alg="$2"
	local out="$TMPHOST/gen-$alg.out"
	local pid
	pid="$(start_node "$out" plain gen "$path" "$alg")"
	if ! wait_pid "$pid" 20 || [ ! -s "$ROOT$path" ] && [ ! -s "$path" ]; then
		echo "FAIL: signer generation failed for $alg"
		cat "$out" 2>/dev/null
		exit 1
	fi
}

pair() {  # pair <name> <listener-mode> <dialer-mode> <signer> <expect: OK|FAIL>
	local name="$1" lmode="$2" dmode="$3" signer="$4" expect="$5"
	local port=$((PORT_BASE++))
	local lout="$TMPHOST/$name.listener" dout="$TMPHOST/$name.dialer"
	local lpid dpid lr dr want

	lpid="$(start_node "$lout" "$lmode" listen "tcp!*!$port" "$signer" alice)"
	if ! wait_for_pattern "$lout" 'listening|FAIL:' 15; then
		echo "FAIL: $name listener did not start"
		cat "$lout" 2>/dev/null
		fails=$((fails+1))
		kill "$lpid" 2>/dev/null
		return
	fi

	dpid="$(start_node "$dout" "$dmode" dial "tcp!127.0.0.1!$port" "$signer" bob)"
	wait_pid "$dpid" 30 >/dev/null 2>&1
	wait_pid "$lpid" 30 >/dev/null 2>&1

	lr="$(grep -Eo 'AUTH-OK|AUTH-FAIL' "$lout" | head -1)"
	dr="$(grep -Eo 'AUTH-OK|AUTH-FAIL' "$dout" | head -1)"
	want="AUTH-$expect"  # OK -> AUTH-OK, FAIL -> AUTH-FAIL
	if [ "$lr" = "$want" ] && [ "$dr" = "$want" ]; then
		echo "PASS: $name (listener=$lr dialer=$dr)"
	else
		echo "FAIL: $name (want $want; listener=$lr dialer=$dr)"
		echo "-- listener output --"
		cat "$lout" 2>/dev/null
		echo "-- dialer output --"
		cat "$dout" 2>/dev/null
		fails=$((fails+1))
	fi
}

make_signer "$SIGNER_ED" ed25519
make_signer "$SIGNER_ML" mldsa87

pair "both-default-768-ed25519"   plain plain "$SIGNER_ED" OK
pair "both-cnsa-1024-ed25519"     cnsa  cnsa  "$SIGNER_ED" OK
pair "both-cnsa-1024-mldsa87"     cnsa  cnsa  "$SIGNER_ML" OK
pair "mixed-1024-vs-768-mldsa87"  cnsa  plain "$SIGNER_ML" FAIL

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "CNSA two-node: ALL PASS"
	exit 0
else
	echo "CNSA two-node: $fails FAILED"
	exit 1
fi
