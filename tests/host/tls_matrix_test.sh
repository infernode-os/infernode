#!/bin/bash
#
# tests/host/tls_matrix_test.sh
#
# The TLS client (appl/lib/crypt/tls.b, through dis/tlsperf.dis) against
# OpenSSL's s_server, certificates verified against the test's own roots
# (bound over /lib/certs in emu's name space):
#
#   - TLS 1.3 default (X25519, or X25519MLKEM768 where OpenSSL has it)
#   - TLS 1.3 servers taking only P-256 or only P-384: the client offers
#     those groups without shares, the server asks by HelloRetryRequest
#     and the second ClientHello carries the share (checked in OpenSSL's
#     trace: an HRR sent, a key_share of the group's length after it)
#   - TLS 1.2 with ECDHE over P-256, and with RSA key exchange
#   - ECDSA certificates: a P-256 server key under an RSA root, and a
#     P-384 chain (root and server), over TLS 1.3 and 1.2
#   - refused: a certificate for another name, one from a root not trusted,
#     and one whose issuer has a trusted root's name but not its key (the
#     ECDSA signature does not verify)
#
# Each case's median handshake time is printed (tlsperf's TLS column).
#
# Run from project root: ./tests/host/tls_matrix_test.sh [handshakes per case]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
N="${1:-5}"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/tlsperf.dis" ] && [ -f "$ROOT/dis/lib/crypt/tls.dis" ] || { echo "SKIP: dis/tlsperf.dis or dis/lib/crypt/tls.dis not built"; exit 77; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: no openssl"; exit 77; }

TMP="$(mktemp -d)"
sp=
# only the processes this test started are killed
cleanup() { [ -n "$sp" ] && kill "$sp" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

cd "$TMP" || exit 1
mkdir certs
ossl() { openssl "$@" 2>/dev/null; }
echo "subjectAltName=IP:127.0.0.1,DNS:localhost" >ip.ext
echo "subjectAltName=DNS:wrong.example" >wrong.ext
# sign NAME KEYFILE CA-PEM CA-KEY EXT [digest]
sign() {
	ossl req -new -key "$2" -subj "/CN=$1" -out "$1.csr"
	ossl x509 -req -in "$1.csr" -CA "$3" -CAkey "$4" -CAcreateserial -days 2 -extfile "$5" ${6:+-$6} -out "$1.pem"
}
ossl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=MatrixCA
ossl req -x509 -newkey rsa:2048 -nodes -keyout stranger.key -out stranger.pem -days 2 -subj /CN=Stranger
ossl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out rsa.key
ossl ecparam -name prime256v1 -genkey -noout -out ec256.key
ossl ecparam -name secp384r1 -genkey -noout -out ec384.key
ossl ecparam -name secp384r1 -genkey -noout -out ecca.key
ossl ecparam -name secp384r1 -genkey -noout -out fakeca.key
ossl req -x509 -new -key ecca.key -subj /CN=MatrixECCA -days 2 -sha384 -out ecca.pem
ossl req -x509 -new -key fakeca.key -subj /CN=MatrixECCA -days 2 -sha384 -out fakeca.pem
sign good rsa.key ca.pem ca.key ip.ext;		mv good.pem rsa.pem
sign wrong rsa.key ca.pem ca.key wrong.ext;	mv wrong.pem wrongname.pem
sign untr rsa.key stranger.pem stranger.key ip.ext;	mv untr.pem untrusted.pem
sign e256 ec256.key ca.pem ca.key ip.ext;	mv e256.pem ec256.pem
sign e384 ec384.key ecca.pem ecca.key ip.ext sha384;	mv e384.pem ec384.pem
sign f384 ec384.key fakeca.pem fakeca.key ip.ext sha384;	mv f384.pem forged.pem
ossl x509 -in ca.pem -outform der -out certs/ca.der
ossl x509 -in ecca.pem -outform der -out certs/ecca.der
for f in rsa wrongname untrusted ec256 ec384 forged; do
	[ -s "$f.pem" ] || { echo "FAIL: could not make $f.pem"; exit 1; }
done

PORT=$((20000 + $$ % 20000))
fails=0

# run NAME CERT KEY WANT(OK|FAIL) HRR(group length expected after an HRR, or -) s_server args...
run() {
	local name=$1 cert=$2 key=$3 want=$4 hrr=$5
	shift 5
	PORT=$((PORT+1))
	openssl s_server -accept "$PORT" -cert "$cert.pem" -key "$key.key" -www -trace "$@" >ss.log 2>&1 &
	sp=$!
	for _ in $(seq 1 50); do
		grep -q ACCEPT ss.log 2>/dev/null && break
		sleep 0.1
	done
	with_timeout 120 "$EMU" -c1 -r"$ROOT" sh -c "bind '#U*'$TMP/certs /lib/certs; /dis/tlsperf.dis -n $N https://127.0.0.1:$PORT/" </dev/null >out.log 2>&1
	kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; sp=
	local ok med got=FAIL
	ok=$(grep -c 'HTTP 200' out.log)
	[ "$ok" -eq "$N" ] && got=OK
	med=$(awk '$7==200 {print $3}' out.log | sort -n | awk '{a[NR]=$1} END {if(NR) print a[int((NR+1)/2)] " ms"; else print "-"}')
	if [ "$got" != "$want" ]; then
		echo "FAIL: $name: want $want, got $got"
		grep -v '^URL\|^---\|fsqid' out.log | head -3 | sed 's/^/    /'
		fails=$((fails+1))
		return
	fi
	if [ "$hrr" != - ]; then
		# an HRR's key_share is the selected group alone (2 bytes); the
		# second ClientHello's then carries one share of the group's size
		if ! grep -q 'extension_type=key_share(51), length=2$' ss.log ||
		   ! grep -q "extension_type=key_share(51), length=$hrr\$" ss.log; then
			echo "FAIL: $name: no HelloRetryRequest and $hrr-byte key_share in OpenSSL's trace"
			fails=$((fails+1))
			return
		fi
	fi
	if [ "$got" = OK ]; then
		echo "PASS: $name (median handshake $med)"
	else
		echo "PASS: $name refused: $(grep -o 'ERR .*' out.log | head -1)"
	fi
}

run tls13-default		rsa	rsa	OK -	-tls1_3
run tls13-p256-hrr		rsa	rsa	OK 71	-tls1_3 -groups P-256
run tls13-p384-hrr		rsa	rsa	OK 103	-tls1_3 -groups P-384
run tls12-ecdhe-p256		rsa	rsa	OK -	-tls1_2 -groups P-256
run tls12-rsa-kx		rsa	rsa	OK -	-tls1_2 -cipher AES128-GCM-SHA256
run tls13-ecdsa-p256-cert	ec256	ec256	OK -	-tls1_3
run tls12-ecdsa-p256-cert	ec256	ec256	OK -	-tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256
run tls13-ecdsa-p384-chain	ec384	ec384	OK 103	-tls1_3 -groups P-384
run tls12-ecdsa-p384-chain	ec384	ec384	OK -	-tls1_2 -groups P-384 -cipher ECDHE-ECDSA-AES128-GCM-SHA256
run wrong-name			wrongname rsa	FAIL -	-tls1_3
run untrusted-root		untrusted rsa	FAIL -	-tls1_3
run forged-ecdsa-signature	forged	ec384	FAIL -	-tls1_3

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "TLS matrix: ALL PASS"
	exit 0
fi
echo "TLS matrix: $fails FAILED"
exit 1
