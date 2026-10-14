#!/bin/bash
#
# TLS hybrid key exchange interop regression.
#
# Drives the Inferno TLS client (tests/tlsclient.b) against an OpenSSL s_server
# and asserts:
#   1. default client vs X25519MLKEM768 server     -> hybrid (group 11ec)
#   2. default client vs X25519 server             -> classical fallback
#   3. CNSATLS client vs SecP384r1MLKEM1024 server -> CNSA hybrid (group 11ed)
#   4. CNSATLS client vs X25519-only server        -> FAILS (no silent downgrade)
#   5. CNSATLS client vs TLS 1.2 server            -> FAILS
#   6. CNSAMODE alone vs X25519 server             -> succeeds: CNSAMODE governs
#      the native STS handshake between nodes, not TLS
#
# Requires a built emu and OpenSSL >= 3.5 (ML-KEM + the hybrid groups).
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"
LIMBO="${LIMBO:-$ROOT/MacOSX/arm64/bin/limbo}"
[ -x "$LIMBO" ] || LIMBO="$ROOT/Linux/amd64/bin/limbo"

# find an OpenSSL that knows the hybrid groups (macOS default is LibreSSL)
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
TMP="$(mktemp -d)"
CERT="$TMP/c.pem"; KEY="$TMP/k.pem"
fails=0
# Only the processes this test started are killed: never every o.emu, which
# would take a developer's running session with it.
sp=; cp=
cleanup(){ [ -n "$sp" ] && kill -9 "$sp" 2>/dev/null; [ -n "$cp" ] && kill -9 "$cp" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

"$OSSL" req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -days 1 -nodes -subj "/CN=localhost" 2>/dev/null
"$LIMBO" -gw -I"$ROOT/module" -o "$ROOT/dis/tests/tlsclient.dis" "$ROOT/tests/tlsclient.b" 2>&1 | head -3

# case_run <name> <env: none|CNSATLS|CNSAMODE> <expect: OK|FAIL> <want group or -> <s_server args...>
case_run(){
	local name="$1" env="$2" expect="$3" group="$4"; shift 4
	PORT=$((PORT+1))
	"$OSSL" s_server -accept "$PORT" -naccept 1 -cert "$CERT" -key "$KEY" -www -quiet "$@" >"$TMP/ss" 2>&1 &
	sp=$!
	sleep 1
	local out="$TMP/tc"
	case $env in
	CNSATLS)	CNSATLS=1 "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" </dev/null >"$out" 2>&1 & ;;
	CNSAMODE)	CNSAMODE=1 "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" </dev/null >"$out" 2>&1 & ;;
	*)		env -u CNSATLS -u CNSAMODE "$EMU" -r"$ROOT" /dis/tests/tlsclient.dis "tcp!127.0.0.1!$PORT" </dev/null >"$out" 2>&1 & ;;
	esac
	cp=$!
	# the client prints its verdict and the reply, then exits
	for _ in $(seq 1 60); do
		kill -0 "$cp" 2>/dev/null || break
		grep -q 'DATA-\|HANDSHAKE-FAIL\|FAIL:' "$out" 2>/dev/null && break
		sleep 0.5
	done
	kill -9 "$cp" 2>/dev/null; kill -9 "$sp" 2>/dev/null
	wait "$cp" "$sp" 2>/dev/null; cp=; sp=
	local got=FAIL
	grep -q HANDSHAKE-OK "$out" && got=OK
	if [ "$got" = OK ] && [ "$group" != - ] && ! grep -q "group=$group" "$out"; then
		echo "FAIL: $name (want group $group)"; cat "$out"; fails=$((fails+1))
	elif [ "$got" = "$expect" ]; then
		echo "PASS: $name ($got)"
	else
		echo "FAIL: $name (want $expect, got $got)"; cat "$out" 2>/dev/null; fails=$((fails+1))
	fi
	rm -f "$out" "$TMP/ss"
}

case_run "default-hybrid-x25519mlkem768"  none     OK   11ec -tls1_3 -groups X25519MLKEM768
case_run "default-x25519-fallback"        none     OK   001d -tls1_3 -groups X25519
case_run "cnsatls-secp384r1mlkem1024"     CNSATLS  OK   11ed -tls1_3 -groups SecP384r1MLKEM1024
case_run "cnsatls-vs-x25519-rejected"     CNSATLS  FAIL -    -tls1_3 -groups X25519
case_run "cnsatls-vs-tls12-rejected"      CNSATLS  FAIL -    -tls1_2 -cipher AES128-GCM-SHA256
case_run "cnsamode-leaves-tls-alone"      CNSAMODE OK   001d -tls1_3 -groups X25519

echo "----"
if [ "$fails" -eq 0 ]; then echo "TLS hybrid: ALL PASS"; exit 0; else echo "TLS hybrid: $fails FAILED"; exit 1; fi
