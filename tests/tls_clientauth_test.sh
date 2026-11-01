#!/bin/bash
#
# TLS 1.3 client-certificate and server key-pinning interop regression.
#
# Drives tests/tlspinclient.b against an OpenSSL s_server that demands a
# client certificate (-Verify 1), as a styxbrick does, and asserts:
#   1. our cert + correct pin                 -> server accepts our cert
#   2. same, over secp256r1 and ChaCha20       -> OK
#   3. correct pin but no client certificate   -> server refuses (DATA-FAIL)
#   4. wrong pin                               -> HANDSHAKE-FAIL
#   5. client key that does not match its cert -> server refuses CertificateVerify
#   6. pin, no cert, server not asking         -> OK (pinning alone)
#
# The client certificate is made by brick(1) (`brick key`), so this also
# checks that OpenSSL accepts the certificates brick generates.
#
# Requires a built emu and OpenSSL 3.
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"
LIMBO="${LIMBO:-$ROOT/MacOSX/arm64/bin/limbo}"
for l in "$ROOT/Linux/arm64/bin/limbo" "$ROOT/Linux/amd64/bin/limbo"; do
	[ -x "$LIMBO" ] || LIMBO="$l"
done
OSSL="${OPENSSL:-openssl}"
command -v "$OSSL" >/dev/null || { echo "SKIP: no openssl"; exit 0; }
[ -x "$EMU" ] || { echo "FAIL: no emu found (set EMU)"; exit 1; }
[ -x "$LIMBO" ] || { echo "FAIL: no Limbo compiler found (set LIMBO)"; exit 1; }

PORT=14533
# The emu sees $ROOT as /, so keys live under it.
REL=tmp/tls_clientauth.$$
TMP="$ROOT/$REL"
mkdir -p "$TMP"
fails=0
sp=; cp=
cleanup(){ [ -n "$sp" ] && kill -9 "$sp" 2>/dev/null; [ -n "$cp" ] && kill -9 "$cp" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

"$LIMBO" -gw -I"$ROOT/module" -o "$ROOT/dis/tests/tlspinclient.dis" "$ROOT/tests/tlspinclient.b" 2>&1 | head -3

# Server: a self-signed P-256 certificate with a name nobody would check.
"$OSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout "$TMP/sk.pem" \
	-out "$TMP/sc.pem" -days 1 -nodes -subj "/CN=nobody-checks-this" 2>/dev/null
PIN=$("$OSSL" x509 -in "$TMP/sc.pem" -noout -pubkey | "$OSSL" pkey -pubin -outform DER | sha256sum | cut -c1-64)
BADPIN=$(echo "$PIN" | tr '0-9a-f' '1-9a-f0')

# Client: brick's own key and certificate; and a copy whose key is wrong.
"$EMU" -r"$ROOT" sh -c "brick key -d /$REL/k; brick key -d /$REL/other" </dev/null >/dev/null 2>&1
mkdir -p "$TMP/badk"
cp "$TMP/k/client.crt" "$TMP/badk/client.crt"
cp "$TMP/other/client.key" "$TMP/badk/client.key"
"$OSSL" x509 -inform DER -in "$TMP/k/client.crt" -out "$TMP/cc.pem"

# case_run <name> <expect: DATA|HSFAIL|DATAFAIL> <client args> -- <s_server args...>
case_run(){
	local name="$1" expect="$2" cargs="$3"; shift 4
	PORT=$((PORT+1))
	"$OSSL" s_server -accept "$PORT" -naccept 1 -cert "$TMP/sc.pem" -key "$TMP/sk.pem" \
		-tls1_3 -www -quiet "$@" >"$TMP/ss" 2>&1 &
	sp=$!
	sleep 1
	local out="$TMP/tc"
	"$EMU" -r"$ROOT" /dis/tests/tlspinclient.dis $cargs "tcp!127.0.0.1!$PORT" </dev/null >"$out" 2>&1 &
	cp=$!
	for _ in $(seq 1 60); do
		kill -0 "$cp" 2>/dev/null || break
		grep -q 'DATA-\|HANDSHAKE-FAIL\|FAIL:' "$out" 2>/dev/null && break
		sleep 0.5
	done
	kill -9 "$cp" 2>/dev/null; kill -9 "$sp" 2>/dev/null
	wait "$cp" "$sp" 2>/dev/null; cp=; sp=
	local got=OTHER
	grep -q DATA-OK "$out" && got=DATA
	grep -q DATA-FAIL "$out" && got=DATAFAIL
	grep -q HANDSHAKE-FAIL "$out" && got=HSFAIL
	if [ "$got" = "$expect" ]; then
		echo "PASS: $name ($got)"
	else
		echo "FAIL: $name (want $expect, got $got)"; cat "$out" "$TMP/ss" 2>/dev/null; fails=$((fails+1))
	fi
	rm -f "$out" "$TMP/ss"
}

V="-Verify 1 -CAfile $TMP/cc.pem"
case_run "cert-and-pin"            DATA     "-d /$REL/k -p $PIN"    -- $V
case_run "cert-and-pin-p256-chacha" DATA    "-d /$REL/k -p $PIN"    -- $V -groups P-256 -ciphersuites TLS_CHACHA20_POLY1305_SHA256
case_run "no-cert-refused"         DATAFAIL "-p $PIN"               -- $V
case_run "wrong-pin-rejected"      HSFAIL   "-d /$REL/k -p $BADPIN" -- $V
case_run "wrong-key-refused"       DATAFAIL "-d /$REL/badk -p $PIN" -- $V
case_run "pin-only"                DATA     "-p $PIN"               --

echo "----"
if [ "$fails" -eq 0 ]; then echo "TLS client auth: ALL PASS"; exit 0; else echo "TLS client auth: $fails FAILED"; exit 1; fi
