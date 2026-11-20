#!/bin/bash
#
# tests/host/tls_keyupdate_test.sh
#
# TLS 1.3 KeyUpdate (RFC 8446 4.6.3, 7.2) between appl/lib/crypt/tls.b and
# OpenSSL, on the loopback, each as client and as server.
# tests/tls_record_test.b checks every post-handshake message against keys
# the test derives itself; this checks the same key schedule against
# another implementation's.
#
#   - httpd(8) (tls->server) with openssl s_client: s_client sends a
#     KeyUpdate that asks for one back, then a request under its new key.
#     The server must read the request with the new key, and answer with
#     its own KeyUpdate and a response under the key that follows it:
#     s_client prints the page.  (The server answered a KeyUpdate from its
#     reader, beside whatever its writer was sending; now the writer sends
#     it, before its next record.)  Twice on one connection, then a
#     KeyUpdate that asks for none.
#   - tlsperf (tls->client) with openssl s_server: s_server sends a
#     KeyUpdate and then its reply under the new key, and tlsperf reads
#     the reply's status line.  s_server's two NewSessionTickets come
#     first, as in every TLS 1.3 handshake with it.
#
# Needs openssl.  Nothing but 127.0.0.1.
#
# Run from project root: ./tests/host/tls_keyupdate_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/httpd/httpd.dis dis/tlsperf.dis dis/lib/crypt/tls.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v openssl >/dev/null 2>&1 || { echo "SKIP: no openssl"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

TMP="$(mktemp -d)"
pids=
# only the processes this test started are killed; KEEP=dir keeps the logs
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; [ -n "$KEEP" ] && cp -r "$TMP" "$KEEP"; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

fails=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }
pass() { echo "PASS: $*"; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

cd "$TMP" || exit 1
mkdir site certs
echo 'the page behind a KeyUpdate' >site/index.html
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out cert.pem \
	-days 2 -subj /CN=localhost -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' 2>/dev/null
[ -s cert.pem ] || { echo "FAIL: could not make a certificate"; exit 1; }
openssl x509 -in cert.pem -outform der -out certs/ca.der 2>/dev/null
IN="#U*$TMP"

# ---- the server's end: httpd and s_client
P1=$(freeport)
with_timeout 120 "$EMU" -c1 -r"$ROOT" sh -c "svc/httpd/httpd -c '$IN/cert.pem' -k '$IN/key.pem' -a 'tcp!127.0.0.1!$P1' '$IN/site'" </dev/null >httpd.log 2>&1 &
pids="$pids $!"
for _ in $(seq 1 100); do
	python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1',$P1)))" 2>/dev/null && break
	sleep 0.1
done
# s_client reads commands at the start of a line: K is a KeyUpdate that
# asks for one back, k one that does not
req() { printf 'GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n'; }
( printf 'K\n'; sleep 0.5; req; sleep 1; printf 'K\n'; sleep 0.5; req; sleep 1; printf 'k\n'; sleep 0.5; req; sleep 1 ) |
	with_timeout 30 openssl s_client -connect "127.0.0.1:$P1" -tls1_3 -CAfile cert.pem -verify_return_error -msg >sc.log 2>&1
n=$(grep -c 'the page behind a KeyUpdate' sc.log)
if [ "$n" -eq 3 ]; then
	pass "the server reads three requests, each after s_client's KeyUpdate"
else
	fail "s_client got the page $n times of 3: $(grep -a 'error\|alert' sc.log | head -2 | tr '\n' ' ')"
fi
# what s_client's trace shows of the server's own: a KeyUpdate received
# for each that asked (-msg marks records it reads with <<<)
got=$(grep -c '^<<< TLS 1.3, Handshake \[length 0005\], KeyUpdate' sc.log)
sent=$(grep -c '^>>> TLS 1.3, Handshake \[length 0005\], KeyUpdate' sc.log)
if [ "$sent" -eq 3 ] && [ "$got" -eq 2 ]; then
	pass "the server answered each KeyUpdate that asked with one of its own, and the one that did not with none"
else
	fail "s_client sent $sent KeyUpdates (3) and received $got (2)"
fi
if grep -aq 'bad record mac\|decryption failed\|alert' sc.log; then
	fail "s_client reports: $(grep -a 'bad record mac\|decryption failed\|alert' sc.log | head -1)"
fi

# ---- the client's end: tlsperf and s_server
P2=$(freeport)
# s_server sends what it reads on standard input; K at the start of a line is a KeyUpdate
( sleep 3; printf 'K\n'; sleep 0.5; printf 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'; sleep 3 ) |
	openssl s_server -accept "127.0.0.1:$P2" -cert cert.pem -key key.pem -tls1_3 -msg >ss.log 2>&1 &
pids="$pids $!"
for _ in $(seq 1 100); do
	python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1',$P2)))" 2>/dev/null && break
	sleep 0.1
done
with_timeout 60 "$EMU" -c1 -r"$ROOT" sh -c "bind '$IN/certs' /lib/certs; /dis/tlsperf.dis -n 1 https://127.0.0.1:$P2/; echo halt > /dev/sysctl" </dev/null >perf.log 2>&1
if grep -q 'HTTP 200\| 200 ' perf.log && grep -q '^>>> TLS 1.3, Handshake \[length 0005\], KeyUpdate' ss.log; then
	pass "the client reads s_server's reply under the key its KeyUpdate promised, after its two tickets"
else
	fail "the client did not read the reply after s_server's KeyUpdate: $(grep -v '^URL\|^---' perf.log | head -2 | tr '\n' ' ')"
fi

if [ $fails -ne 0 ]; then
	echo "tls_keyupdate_test: $fails failed"
	exit 1
fi
echo "PASS: tls_keyupdate_test"
exit 0
