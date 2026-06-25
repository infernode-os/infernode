#!/bin/bash
#
# CNSA 2.0 TLS hybrid (SecP384r1MLKEM1024) interop regression.
#
# Drives the Inferno TLS client (tests/tlsclient.b) against an OpenSSL s_server
# and asserts:
#   1. CNSA client  vs SecP384r1MLKEM1024 server -> hybrid handshake succeeds
#   2. default client vs X25519 server           -> classical handshake succeeds
#   3. CNSA client  vs X25519-only server        -> FAILS (no silent downgrade)
#
# Requires a built emu and OpenSSL >= 3.5 (ML-KEM + the hybrid groups).
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"
LIMBO="${LIMBO:-$ROOT/MacOSX/arm64/bin/limbo}"
[ -x "$LIMBO" ] || LIMBO="$ROOT/Linux/amd64/bin/limbo"

# find an OpenSSL that knows SecP384r1MLKEM1024 (macOS default is LibreSSL)
OSSL="${OPENSSL:-}"
if [ -z "$OSSL" ]; then
	for c in /opt/homebrew/Cellar/openssl@3/*/bin/openssl /opt/homebrew/bin/openssl openssl; do
		if [ -x "$(command -v "$c" 2>/dev/null)" ] && "$c" list -tls-groups 2>/dev/null | grep -qi SecP384r1MLKEM1024; then
			OSSL="$c"; break
		fi
	done
fi
[ -n "$OSSL" ] || { echo "SKIP: no OpenSSL with SecP384r1MLKEM1024 found"; exit 0; }
[ -x "$LIMBO" ] || { echo "FAIL: no Limbo compiler found"; exit 1; }

PORT=14433
CERT="/tmp/tlscnsa-c.$$.pem"; KEY="/tmp/tlscnsa-k.$$.pem"
fails=0
cleanup(){ pkill -9 -f "s_server -accept $PORT" 2>/dev/null; pkill -9 -f o.emu 2>/dev/null; rm -f "$CERT" "$KEY"; }
trap cleanup EXIT INT TERM

"$OSSL" req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -days 1 -nodes -subj "/CN=localhost" 2>/dev/null
"$LIMBO" -gw -I"$ROOT/module" -o "$ROOT/dis/tests/tlsclient.dis" "$ROOT/tests/tlsclient.b" 2>&1 | head -3

case_run(){  # case_run <name> <mode: cnsa|plain> <server-groups> <expect: OK|FAIL>
	local name="$1" mode="$2" groups="$3" expect="$4"
	pkill -9 -f "s_server -accept $PORT" 2>/dev/null; pkill -9 -f o.emu 2>/dev/null; sleep 1
	( "$OSSL" s_server -accept "$PORT" -cert "$CERT" -key "$KEY" -tls1_3 -groups "$groups" -www -quiet ) >/tmp/ss.$$ 2>&1 &
	local sp=$!
	sleep 1
	local out="/tmp/tc.$$"
	if [ "$mode" = cnsa ]; then
		( CNSAMODE=1 "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" 2>&1 </dev/null ) > "$out" &
	else
		( "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" 2>&1 </dev/null ) > "$out" &
	fi
	local p=$!; sleep 15; kill "$p" 2>/dev/null; pkill -9 -f o.emu 2>/dev/null
	kill -9 "$sp" 2>/dev/null; wait "$sp" 2>/dev/null || true
	pkill -9 -f "s_server -accept $PORT" 2>/dev/null
	local got=FAIL
	grep -q HANDSHAKE-OK "$out" && got=OK
	if [ "$got" = "$expect" ]; then
		echo "PASS: $name ($got)"
	else
		echo "FAIL: $name (want $expect, got $got)"; cat "$out" 2>/dev/null; fails=$((fails+1))
	fi
	rm -f "$out" /tmp/ss.$$
}

case_run_tls12(){  # CNSA mode must reject a TLS 1.2 server even if the suite is otherwise supported
	local name="$1" expect="$2"
	pkill -9 -f "s_server -accept $PORT" 2>/dev/null; pkill -9 -f o.emu 2>/dev/null; sleep 1
	( "$OSSL" s_server -accept "$PORT" -cert "$CERT" -key "$KEY" -tls1_2 -cipher AES128-GCM-SHA256 -www -quiet ) >/tmp/ss.$$ 2>&1 &
	local sp=$!
	sleep 1
	local out="/tmp/tc.$$"
	( CNSAMODE=1 "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" 2>&1 </dev/null ) > "$out" &
	local p=$!; sleep 15; kill "$p" 2>/dev/null; pkill -9 -f o.emu 2>/dev/null
	kill -9 "$sp" 2>/dev/null; wait "$sp" 2>/dev/null || true
	pkill -9 -f "s_server -accept $PORT" 2>/dev/null
	local got=FAIL
	grep -q HANDSHAKE-OK "$out" && got=OK
	if [ "$got" = "$expect" ]; then
		echo "PASS: $name ($got)"
	else
		echo "FAIL: $name (want $expect, got $got)"; cat "$out" 2>/dev/null; fails=$((fails+1))
	fi
	rm -f "$out" /tmp/ss.$$
}

case_run "cnsa-hybrid-secp384r1mlkem1024" cnsa  SecP384r1MLKEM1024 OK
case_run "default-x25519-regression"      plain X25519             OK
case_run "cnsa-vs-x25519-only-rejected"   cnsa  X25519             FAIL
case_run_tls12 "cnsa-vs-tls12-rsa-rejected" FAIL

echo "----"
if [ "$fails" -eq 0 ]; then echo "TLS CNSA hybrid: ALL PASS"; exit 0; else echo "TLS CNSA hybrid: $fails FAILED"; exit 1; fi
