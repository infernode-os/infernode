#!/bin/bash
#
# tests/host/httpd_auth_test.sh
#
# httpd(8)'s authentication from outside: tests/host/httpd/auth.py
# against four servers in one emu, with a CA, an intermediate, another
# CA, client certificates and a CRL made here by OpenSSL, and a
# password file made by svc/httpd/passwd:
#
#   rules     TLS, -A (CA and its CRL), -P, -x (below), -p /led/ctl
#   defaults  TLS, -A, -P, -p /led/ctl, no -x
#   plain     no TLS, -x naming only /open (none)
#   lockout   TLS, -P, -x "/ password", for the lockout
#
# Client certificates: from the CA (alice), from the intermediate sent
# with it (bob) and without it, for server authentication only, from
# another CA, revoked, self-signed; by CN and by fingerprint.
# Passwords: right, wrong, unknown users, malformed Authorization, two
# of them, a 401 then the password on one connection, the hash cached,
# an unknown user's time, the file changed while serving.  Rules: 14
# ways at /admin (case, dots, blanks, backslashes, an 8.3 name,
# absolute-form, encoded slashes), prefix boundaries, HEAD, methods,
# the defaults, a path no rule names, the log's user field; the
# CertificateRequest naming the CA; ten wrong passwords locking an
# address out.  Then: configurations that must not start (-P without
# TLS, a rule taking what is not configured, a CRL no root signed, a
# bad term, -r with -P), the servers still answering, no fault.
#
# Run from project root: ./tests/host/httpd_auth_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
EMU="${HTTPD_EMU:-$EMU}"
EMUFLAGS="${HTTPD_EMUFLAGS:--c1}"
[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
for f in dis/svc/httpd/httpd.dis dis/svc/httpd/passwd.dis dis/lib/crypt/tls.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done
command -v openssl >/dev/null 2>&1 || { echo "SKIP: no openssl"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

NAME="httpd_auth_test.$$"
W="$ROOT/tmp/$NAME"
T=/tmp/$NAME
mkdir -p "$W" || exit 1
pids=
cleanup() {
	for p in $pids; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
	rm -rf "$W"
}
trap cleanup EXIT INT TERM
cd "$W" || exit 1

# ---------------------------------------------------------------- certificates
q() { openssl "$@" 2>/dev/null; }
ec() { q ecparam -name prime256v1 -genkey -noout -out "$1.key"; }
printf 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > cli.ext
printf 'basicConstraints=CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' > srv.ext
for k in ca int other alice bob srvonly revoked selfsigned server; do ec $k; done
q req -x509 -new -key ca.key -subj "/CN=Test Client CA" -days 2 -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
q req -x509 -new -key other.key -subj "/CN=Other CA" -days 2 -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" -out other.pem
sign() { q req -new -key "$1.key" -subj "/CN=$2" -out "$1.csr"; q x509 -req -in "$1.csr" -CA "$3.pem" -CAkey "$3.key" -CAcreateserial -days 2 -extfile "$4" -out "$1.pem"; }
sign int "Test Intermediate" ca ca.ext
sign alice alice-laptop ca cli.ext
sign bob bob-phone int cli.ext
sign srvonly a-server ca srv.ext
sign revoked mallory ca cli.ext
q req -new -key alice.key -subj "/CN=alice-laptop" -out o.csr; q x509 -req -in o.csr -CA other.pem -CAkey other.key -CAcreateserial -days 2 -extfile cli.ext -out other.chain
cp alice.key other.key2; mv other.key2 other.key.client
q req -x509 -new -key selfsigned.key -subj "/CN=alice-laptop" -days 2 -addext "extendedKeyUsage=clientAuth" -out selfsigned.pem
q req -x509 -new -key server.key -subj "/CN=localhost" -days 2 -addext "subjectAltName=DNS:localhost" -out server.pem
mkdir db; : > db/index.txt; echo 1000 > db/crlnumber
printf '[ca]\ndefault_ca=c\n[c]\ndatabase=db/index.txt\ncrlnumber=db/crlnumber\ndefault_md=sha256\ndefault_crl_days=2\n' > ca.cnf
q ca -config ca.cnf -keyfile ca.key -cert ca.pem -revoke revoked.pem
q ca -config ca.cnf -keyfile ca.key -cert ca.pem -gencrl -out ca.crl
q ca -config ca.cnf -keyfile other.key -cert other.pem -gencrl -out other.crl
for f in ca.pem ca.crl int.pem alice.pem bob.pem srvonly.pem revoked.pem selfsigned.pem server.pem other.chain other.crl; do
	[ -s "$f" ] || { echo "FAIL: could not make $f"; exit 1; }
done
cat ca.pem ca.crl > trust.pem
cat ca.pem other.crl > badtrust.pem
cp alice.pem alice.chain; cp srvonly.pem srvonly.chain; cp revoked.pem revoked.chain; cp selfsigned.pem selfsigned.chain
cat bob.pem int.pem > bob.chain; cp bob.pem bobleaf.chain; cp bob.key bobleaf.key
mv other.key otherca.key; cp alice.key other.key
FP=$(q x509 -in alice.pem -outform der | sha256sum | cut -c1-64)

# ---------------------------------------------------------------- the site
mkdir -p site/public site/admin site/led site/bob site/fp site/open site/secret site/alias site/idx site/wiki site/ev
echo home > site/index.html
echo pub > site/public/ok.txt
echo publicx > site/publicx.txt
echo admin > site/admin/x.txt
: > site/led/ctl
echo bob > site/bob/x.txt
echo fp > site/fp/x.txt
echo open > site/open/x.txt
echo secret > site/secret/x.txt
echo report > site/report.txt; gzip -9 -n -c site/report.txt > site/report.txt.gz
echo index > site/idx/index.html
mkdir -p site/mixed/locked; echo o > site/mixed/open.txt; echo l > site/mixed/locked/x.txt
: > site/ev/feed
cat > rules <<RULES
realm Test site
# who may have what
/		password cert
/public		none
/admin		cert
POST /led	cert=alice-laptop
GET /led	password cert
/bob		password=bob cert=bob-phone
/fp		cert=sha256:$FP
/report.txt	cert
/idx/index.html	cert
POST /wiki	cert
/mixed/locked	cert
RULES
printf '/open none\n' > plainrules
printf 'realm Lockout\n/ password\n' > lockrules
printf '/admin cert\n' > certrules
printf '/x pasword\n' > badrules

pw() { echo "$2" | "$EMU" $EMUFLAGS -r"$ROOT" /dis/svc/httpd/passwd.dis -i "$3" "$1" </dev/stdin 2>&1 | grep "^$1:"; }
{ pw alice opensesame 20000; pw bob bobpass 20000; pw carol carolpass 100000; } > pw
pw dave davepass 20000 > dave.pw
[ "$(wc -l < pw)" -eq 3 ] && [ -s dave.pw ] || { echo "FAIL: svc/httpd/passwd made no lines"; cat pw; exit 1; }
python3 - "$W/pw" <<'PY' && echo "PASS: svc/httpd/passwd's lines are PBKDF2-HMAC-SHA-256 (checked by hashlib)" || { echo "FAIL: svc/httpd/passwd's hash is not PBKDF2"; exit 1; }
import sys, hashlib, base64
want = {"alice": b"opensesame", "bob": b"bobpass", "carol": b"carolpass"}
for l in open(sys.argv[1]):
    u, alg, it, salt, h = l.strip().split(":")
    assert alg == "pbkdf2-sha256" and len(base64.b64decode(salt)) == 16
    assert hashlib.pbkdf2_hmac("sha256", want[u], base64.b64decode(salt), int(it)) == base64.b64decode(h), u
PY

# ---------------------------------------------------------------- refused configurations
refuse() {
	local why=$1 want=$2
	shift 2
	with_timeout 30 "$EMU" $EMUFLAGS -r"$ROOT" sh -c "svc/httpd/httpd $* $T/site; echo exited" </dev/null >refuse.log 2>&1
	if grep -qE "$want" refuse.log && grep -q exited refuse.log; then
		echo "PASS: will not start: $why"
	else
		echo "FAIL: started, or not saying why: $why (want '$want')"; tail -3 refuse.log; fails=$((fails+1))
	fi
}
fails=0
P0=$((21000 + $$ % 15000))
refuse "-P without TLS" "need TLS" -P $T/pw -a tcp!127.0.0.1!$P0
refuse "-A without TLS" "need TLS" -A $T/trust.pem -a tcp!127.0.0.1!$P0
refuse "a rule taking a certificate with no -A" "there is no -A" -c $T/server.pem -k $T/server.key -x $T/certrules -a tcp!127.0.0.1!$P0
refuse "a CRL no root signed" "CRL not signed" -c $T/server.pem -k $T/server.key -A $T/badtrust.pem -a tcp!127.0.0.1!$P0
refuse "a rule that is not one" "not a term" -c $T/server.pem -k $T/server.key -x $T/badrules -a tcp!127.0.0.1!$P0
refuse "-r with -P" "TLS server's|need TLS" -r 443 -P $T/pw -a tcp!127.0.0.1!$P0
refuse "-P with no users in the file" "no users" -c $T/server.pem -k $T/server.key -P $T/rules -a tcp!127.0.0.1!$P0

# ---------------------------------------------------------------- the servers
P1=$((P0+1)); P2=$((P0+2)); P3=$((P0+3)); P4=$((P0+4))
TLSARGS="-c $T/server.pem -k $T/server.key"
cat > run.sh <<INFERNO
load file2chan
# /alias is /admin under another name: what a host that folds case or
# keeps 8.3 names makes of /ADMIN or /ADMINI~1
bind $T/site/admin $T/site/alias
file2chan /chan/authfeed {sleep 1; rread 'café ☕'} {}
bind /chan/authfeed $T/site/ev/feed
svc/httpd/httpd -v -L $TLSARGS -A $T/trust.pem -P $T/pw -x $T/rules -p /led/ctl -w /wiki -l $T/access.log -a tcp!127.0.0.1!$P1 $T/site &
svc/httpd/httpd -v $TLSARGS -A $T/trust.pem -P $T/pw -p /led/ctl -a tcp!127.0.0.1!$P2 $T/site &
svc/httpd/httpd -v -x $T/plainrules -a tcp!127.0.0.1!$P3 $T/site &
svc/httpd/httpd -v $TLSARGS -P $T/pw -x $T/lockrules -a tcp!127.0.0.1!$P4 $T/site &
INFERNO
"$EMU" $EMUFLAGS -r"$ROOT" sh "$T/run.sh" </dev/null >emu.log 2>&1 &
pids="$pids $!"
up() { python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), timeout=1)" 2>/dev/null; }
for _ in $(seq 1 100); do up $P1 && up $P2 && up $P3 && up $P4 && break; sleep 0.1; done
up $P1 && up $P2 && up $P3 && up $P4 || { echo "FAIL: the servers did not start"; cat emu.log; exit 1; }

with_timeout 600 python3 -I "$ROOT/tests/host/httpd/auth.py" $P1 $P2 $P3 $P4 "$W"
fails=$((fails + $?))
if grep -qiE 'panic|SYS: process|broken|sanitizer' emu.log; then
	echo "FAIL: emu reported a fault"; grep -iE 'panic|SYS: process|broken|sanitizer' emu.log | head -5; fails=$((fails+1))
fi
[ "$fails" -eq 0 ] || { echo "--- emu (last 30 lines)"; tail -30 emu.log; }
echo "httpd_auth_test: $fails failed"
[ "$fails" -eq 0 ]
