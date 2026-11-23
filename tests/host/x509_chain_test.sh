#!/bin/bash
#
# tests/host/x509_chain_test.sh
#
# X.509 path validation (appl/lib/crypt/x509.b, RFC 5280 section 6) and
# what the TLS client asks of a server's certificate (appl/lib/crypt/tls.b),
# on chains made for the run by tests/host/x509_chain/gen.py: every byte of
# each certificate and CRL is the generator's, signed with keys made new
# each time.  Two halves.
#
# Chains through the verification entry points (tests/x509_chain.b:
# verify_certchain_roots, and verify_certchain with the test's directories
# bound over /lib/certs and /lib/crls), each ACCEPT or REJECT with a reason:
#   - certificates that are not certificates (a TBSCertificate of no
#     fields, an extension of none, lengths of 16r7fffffff in each of the
#     two DER readers, indefinite lengths, a malformed root and CRL), and
#     RSA keys that are not keys (a modulus of 0 or 1, even, negative,
#     under 2048 bits; an exponent of 0, 1 or even): refused, and never an
#     exception;
#   - a critical extension nobody processes, on a leaf, an issuer and the
#     trust anchor; an extension twice; name constraints on dNSName,
#     iPAddress and directoryName, permitted and excluded, on an issuer,
#     two levels up and on the anchor, against subjectAltName entries,
#     wildcards and a commonName read as a host; a constraint on a form
#     not compared here; policyConstraints that require an explicit policy;
#   - cA FALSE written out (read as TRUE while a BOOLEAN's value was taken
#     from the wrong byte), and TRUE written as 01;
#   - a revoked certificate against a CRL past its nextUpdate, and a CRL
#     that cannot be used, the same from a caller's list and from the
#     store, where the error names the file;
#   - a trust anchor outside its own dates;
#   - one reading for a certificate: its two signature algorithms compared
#     (RFC 5280 4.1.1.2; a CRL's too), an ECDSA signature in DER and
#     nothing else, an EC key that is a point of the curve its certificate
#     names (prime256v1, secp384r1, uncompressed) and an RSA key with NULL
#     parameters, times in RFC 5280 4.1.2.5's two forms only, lengths,
#     INTEGERs, OIDs and strings in DER, names in each string type as
#     their text (a BMPString issuer chains to its UTF8String subject)
#     and none with a NUL, a serial number of -128 not on a CRL that
#     lists 128; ECDSA with SHA-384 and SHA-512 and RSA with SHA-512
#     still taken;
#   - what a path is for: a CA whose extendedKeyUsage leaves out the
#     usage asked for (server, client) issues nothing for it, one or two
#     levels up; the anchor is not asked, and no usage asks nothing;
#   - an intermediate's CRL: it revokes what the intermediate issued,
#     signed by the key the path verified, with cRLSign if the CA has a
#     keyUsage (a root's CRL the same); two levels each with its own; an
#     intermediate given as a trust anchor refused once a root's CRL
#     names it;
#   - whose a CRL is (RFC 5280 6.3.3): one is consulted for what its own
#     issuer issued and for nothing else, a caller's and the store's
#     alike.  An intermediate's CRL, the intermediate no anchor, refuses
#     the leaf it names and takes its sibling, and a chain that does not
#     go through the intermediate (it failed that call); another CA's
#     CRL, a root's or not, changes nothing for a chain that is not that
#     CA's (a CRL some root had not signed failed every root's chains);
#     a CRL its issuer did not sign refuses the paths through that
#     issuer and no other; the store's CRLs are held to their issuers'
#     signatures (they were taken by name: an unsigned file revoked).
#
# Handshakes on the loopback (tests/tlsverify.b: tls->client with
# verification on):
#   - against openssl s_server, whole: a server's certificate with no
#     extended key usage, with serverAuth or anyExtendedKeyUsage taken;
#     one for clientAuth or emailProtection alone, one whose key usage
#     has no digitalSignature, one with an unknown critical extension and
#     one outside its issuer's name constraints refused;
#   - against a scripted TLS 1.2 server (tests/host/x509_chain/fake_tls12.py),
#     which sends its certificate before anything says who it is: the
#     malformed certificates above, and an RSA key of modulus 0 with a
#     one-byte RSA-PSS signature, each a failed handshake and not an
#     exception in the caller; RSA key exchange refused for a key usage
#     without keyEncipherment.
#
# Needs python3 with the cryptography package; the s_server half needs
# openssl too and is left out without it.  Nothing but 127.0.0.1.
#
# Run from project root: ./tests/host/x509_chain_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
HERE="$ROOT/tests/host/x509_chain"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/tests/x509_chain.dis" ] && [ -f "$ROOT/dis/tests/tlsverify.dis" ] || { echo "SKIP: dis/tests/x509_chain.dis or tlsverify.dis not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
python3 -c 'import cryptography' 2>/dev/null || { echo "SKIP: python3 has no cryptography package"; exit 77; }

TMP="$(mktemp -d)"
pids=
# only the processes this test started are killed
cleanup() { for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

IN="#U*$TMP"
python3 "$HERE/gen.py" "$TMP" "$IN" || { echo "FAIL: gen.py could not make the certificates"; exit 1; }

fails=0
passes=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }
pass() { passes=$((passes+1)); if [ -n "$VERBOSE" ]; then echo "PASS: $*"; fi; }

# ---- chains
with_timeout 240 "$EMU" -c1 -r"$ROOT" /dis/tests/x509_chain.dis "$IN/cases" </dev/null >"$TMP/out" 2>&1
grep -q '^DONE$' "$TMP/out" || fail "x509_chain did not finish: $(tail -2 "$TMP/out" | tr '\n' ' ' | cut -c1-300)"
while read -r label want why; do
	got=$(grep -a "^$label: " "$TMP/out" | head -1 | sed "s/^$label: //")
	case "$got" in
	"$want"*)
		if [ -n "$why" ] && ! printf '%s' "$got" | grep -qF -- "$why"; then
			fail "$label: refused, but not for \"$why\": $got"
		else
			pass "$label: $got"
		fi ;;
	*)	fail "$label: want $want${why:+ ($why)}, got ${got:-nothing}" ;;
	esac
done <"$TMP/expect"
# the administrator of a store is told of a CRL that is stale, and of one that cannot be used
if grep -aq 'stale.der: this CRL is past its nextUpdate' "$TMP/out"; then
	pass "a stale CRL in the store is named on standard error"
else
	fail "nothing on standard error names the stale CRL in the store"
fi
if grep -aq 'junk.der: .*no certificate verifies' "$TMP/out"; then
	pass "a CRL that cannot be read is named on standard error"
else
	fail "nothing on standard error names the CRL that cannot be read"
fi
chains=$passes

# ---- handshakes
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
have_openssl=1
command -v openssl >/dev/null 2>&1 || have_openssl=0
T="$TMP/tls"
: >"$TMP/client.sh"
echo "bind '$IN/tls/roots' /lib/certs" >>"$TMP/client.sh"
skipped=0
while read -r label kind ask want why; do
	port=$(freeport)
	if [ "$kind" = server ]; then
		if [ $have_openssl = 0 ]; then
			skipped=$((skipped+1))
			continue
		fi
		chain=
		[ -f "$T/$label.chain.pem" ] && chain="-cert_chain $T/$label.chain.pem"
		openssl s_server -accept "127.0.0.1:$port" -cert "$T/$label.pem" -key "$T/leaf.key" $chain -www >"$T/$label.srv" 2>&1 &
		pids="$pids $!"
	else
		key="$T/leaf.key"
		python3 "$HERE/fake_tls12.py" "$port" "$kind" "$key" "$T/$label".*.der >"$T/$label.srv" 2>&1 &
		pids="$pids $!"
	fi
	echo "/tests/tlsverify.dis $label 'tcp!127.0.0.1!$port' $ask" >>"$TMP/client.sh"
	echo "$label $kind $want $why" >>"$TMP/tls.expect"
done <"$T/cases"
# wait for the last server to listen
for _ in $(seq 1 100); do
	n=$(cat "$T"/*.srv 2>/dev/null | grep -c 'ACCEPT\|listening')
	[ "$n" -ge "$(wc -l <"$TMP/tls.expect")" ] && break
	sleep 0.1
done
echo "echo halt > /dev/sysctl" >>"$TMP/client.sh"
with_timeout 240 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$IN/client.sh" </dev/null >"$TMP/tls.out" 2>&1
while read -r label kind want why; do
	got=$(grep -a "^$label: " "$TMP/tls.out" | head -1 | sed "s/^$label: //")
	case "$got" in
	EXCEPTION*|"")
		fail "$label: the handshake ended its caller: ${got:-no answer} $(grep -a 'Broken' "$TMP/tls.out" | head -1)"
		continue ;;
	esac
	case "$want" in
	OK)
		case "$got" in
		OK*)	pass "$label: handshake completes" ;;
		*)	fail "$label: want a handshake, got $got" ;;
		esac ;;
	FAIL)
		case "$got" in
		FAIL*)
			if [ "$why" != - ] && ! printf '%s' "$got" | grep -qF -- "$why"; then
				fail "$label: refused, but not for \"$why\": $got"
			elif [ "$kind" != server ] && ! grep -q CLIENT-STOPPED "$T/$label.srv"; then
				fail "$label: the client went on after the certificate: $(tail -1 "$T/$label.srv")"
			else
				pass "$label: $got"
			fi ;;
		*)	fail "$label: want a refusal, got $got" ;;
		esac ;;
	CONTINUES)
		# the scripted server stops after its ServerHelloDone: the client
		# took the certificate if it sent its key exchange
		if grep -q CLIENT-CONTINUED "$T/$label.srv"; then
			pass "$label: the client took the certificate"
		else
			fail "$label: the client stopped at the certificate: $got"
		fi ;;
	esac
done <"$TMP/tls.expect"

if [ $fails -ne 0 ]; then
	echo "x509_chain_test: $fails failed, $passes passed"
	exit 1
fi
note=
[ $skipped -ne 0 ] && note=" ($skipped whole handshakes left out: no openssl)"
echo "PASS: x509_chain_test: $chains chains and $((passes-chains)) handshakes as they should be$note"
exit 0
