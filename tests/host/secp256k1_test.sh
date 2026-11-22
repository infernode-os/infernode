#!/bin/bash
#
# tests/host/secp256k1_test.sh
#
# libsec/secp256k1.c, the curve under keyring's secp256k1_* (Ethereum
# keys and transaction signatures: appl/lib/wallet.b, ethcrypto.b), built
# on the host with tests/host/secp256k1/k1test.c:
#
#   - known answers (tests/host/secp256k1/vectors.txt, made by gen.py, a
#     Python reference checked against OpenSSL): d*G; signatures byte for
#     byte (RFC 6979 nonces, low S, v); recovery, of high S too, and of the
#     other parity, refused for r or s 0 or at or past n, an r that is no
#     point's x, and a key at infinity (s R = e G); verification
#   - the complete addition formulas' edge cases, keys 0, n, n-1, field and
#     scalar multiplication, inversion and square root against a slow
#     reference, keygen/sign/recover/verify round trips
#   - constant time (ctgrind): with valgrind, each operation is run with its
#     secret marked undefined (the private key, the random new key, or the
#     operands); memcheck reports any branch or address depending on it.
#     Field and scalar multiplication and reduction, field and scalar
#     (nonce) inversion, and scalar multiplication must give no report;
#     the rest only in the decisions that are public by design: a key or
#     an RFC 6979 candidate out of [1, n-1] (scalarok, its callers), a
#     result that is the identity (ptaffine), a public key checked on the
#     curve (ptload, pubfrompriv), r or s zero (secp256k1_sign, both
#     published in the signature)
#   - no divide instruction and no libmp in the object: the reduction is
#     Montgomery's, not a long division
#
# CC=clang checks clang's code as well as cc's, as ecc_test.sh does.
# The constant-time check needs valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/secp256k1_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/secp256k1"
L="$ROOT/libsec"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -w"
# what RFC 6979's HMAC-SHA256 needs from libsec
LIBSEC="$L/hmac.c $L/sha2.c $L/sha256block.c $L/sha256arm64.c $L/sha512block.c $L/sha1.c $L/sha1block.c $L/md5.c $L/md5block.c $L/securezero.c"

fails=0

if ! $CC $CFLAGS $INC -o "$TMP/k1test" "$D/k1test.c" $LIBSEC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: k1test does not compile"
	exit 1
fi
if "$TMP/k1test" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	cat "$TMP/out"
	echo "PASS: known answers, edge cases, arithmetic, round trips"
else
	cat "$TMP/out"
	echo "FAIL: k1test"
	fails=$((fails+1))
fi

# no division: a divide's time depends on its operands on most cores
# (cf. tests/host/mldsa_decompose_test.sh), and libmp is not to be used
if command -v objdump >/dev/null 2>&1; then
	case "$(uname -m)" in
	x86_64|amd64)	divre='\<i?div[bwlq]?\>' ;;
	aarch64|arm64)	divre='\<[su]div\>' ;;
	riscv64)	divre='\<(div|divu|divw|divuw|rem|remu|remw|remuw)\>' ;;
	*)		divre='' ;;
	esac
	$CC $CFLAGS $INC -c -o "$TMP/secp256k1.o" "$L/secp256k1.c"
	if [ -n "$divre" ] && objdump -d "$TMP/secp256k1.o" | grep -E -q "$divre"; then
		echo "FAIL: secp256k1.o has a divide instruction:"
		objdump -d "$TMP/secp256k1.o" | grep -E "$divre" | head -5
		fails=$((fails+1))
	elif nm -u "$TMP/secp256k1.o" | grep -E -q '\<_?(mp[a-z0-9]+|betomp|mptobe)\>'; then
		echo "FAIL: secp256k1.o calls libmp:"
		nm -u "$TMP/secp256k1.o" | grep -E '\<_?(mp[a-z0-9]+|betomp|mptobe)\>'
		fails=$((fails+1))
	else
		echo "PASS: no divide instruction, no libmp"
	fi
else
	echo "SKIP: divide check (no objdump)"
fi

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
else
	ccs="$CC"
	command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
	for cc in $ccs; do
		$cc $CFLAGS -DCTGRIND $INC -o "$TMP/k1test-ct" "$D/k1test.c" $LIBSEC || { echo "FAIL: k1test -DCTGRIND does not compile with $cc"; exit 1; }
		for what in fieldmul fieldinv scalarmul scalarinv ptmul pubkey keygen sign; do
			valgrind --error-limit=no --read-inline-info=yes --log-file="$TMP/vg.$what" "$TMP/k1test-ct" ct "$what" >/dev/null 2>&1
			# the function each report is in
			awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$TMP/vg.$what" | sort | uniq -c >"$TMP/fns.$what"
			case $what in
			fieldmul|fieldinv|scalarmul|scalarinv|ptmul)
				bad=$(awk '{print $2}' "$TMP/fns.$what") ;;
			*)
				bad=$(awk '{print $2}' "$TMP/fns.$what" | grep -v -x 'scalarok\|rfc6979\|ptaffine\|ptload\|pubfrompriv\|secp256k1_keygen\|secp256k1_sign') ;;
			esac
			if ! grep -q 'ERROR SUMMARY' "$TMP/vg.$what"; then
				echo "FAIL: $cc: $what: valgrind did not run"
				fails=$((fails+1))
			elif [ -n "$bad" ]; then
				echo "FAIL: $cc: $what: branches or addresses depend on the secret in:"
				sed 's/^/    /' "$TMP/fns.$what"
				fails=$((fails+1))
			else
				echo "PASS: $cc: $what constant time ($(awk '{n+=$1} END {print n+0}' "$TMP/fns.$what") public decisions)"
			fi
		done
	done
fi

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "secp256k1: ALL PASS"
	exit 0
fi
echo "secp256k1: $fails FAILED"
exit 1
