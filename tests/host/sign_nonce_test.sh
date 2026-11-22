#!/bin/bash
#
# tests/host/sign_nonce_test.sh
#
# The nonces of libsec's DSA and ElGamal signatures (dsasign.c,
# egsign.c, nonce.c, mpnonce.c) on the host under AddressSanitizer
# (tests/host/sign_nonce/noncetest.c).  ECDSA's are in ecc_test.sh,
# held to RFC 6979's own vectors.
#
# The nonce was the random number generator's alone: one whose state
# repeats signed two messages with one nonce, which gives the key to
# whoever sees both signatures; and its inverse was made by the
# extended binary GCD, every step of which follows the nonce's bits.
#
#   - with no random bytes a signature is the one RFC 6979's nonce
#     gives (tests/host/sign_nonce/vectors.txt, from gen.py's reading of
#     the RFC with hashlib's HMAC): DSA with q of 160, 256 and 163 bits
#     (bits2int's shift), the 256-bit ones checked by OpenSSL's
#     verifier when the vectors were made; ElGamal on a safe prime
#   - with random bytes given, the signature the RFC's 3.6 gives
#   - dsasign and egsign draw from the generator, give another
#     signature each time, and it verifies
#   - with a generator that repeats, two messages do not get one nonce
#   - a q that is not prime, or a generator of 0, is no signature and
#     an end (it was a raise with the VM let go, or no end)
#   - constant time (ctgrind): with valgrind, DSA's key and the random
#     bytes marked undefined.  What is reported is in the decisions
#     that are public by design (a candidate out of range dropped; r or
#     s zero) and in the division of alpha^k mod p by q, a number the
#     verifier computes too.  Nothing is reported in the inversion or
#     the products; the arithmetic dsasign had must be caught by the
#     same check.  ElGamal's is run and what it reports printed: its
#     arithmetic mod p-1 is libmp's general one, on blinded numbers
#     (see egsign.c)
#
# The constant-time check needs valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/sign_nonce_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/sign_nonce"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

PLAIN="-g -O -fno-strict-aliasing -w"
CFLAGS="$PLAIN"
echo 'int main(void){return 0;}' > "$TMP/san.c"
if $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null && "$TMP/san"; then
	CFLAGS="$CFLAGS -fsanitize=address,undefined -fno-sanitize-recover=undefined"
fi
INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# (SIGN_SRC: a directory with another libsec's sources, to see what they do)
LIBSEC="${SIGN_SRC:-$ROOT/libsec}"
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod mpexp mpextendedgcd mpinvert \
	betomp letomp mptobe mprand mptoi mptoui mpfmt strtomp; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done
for f in dsasign dsaverify dsaalloc egsign egverify egalloc nonce mpnonce hmac sha1 sha1block \
	sha2 sha256block sha256arm64 sha512block md5 md5block securezero probably_prime smallprimetest; do
	[ -f "$LIBSEC/$f.c" ] && SRCS="$SRCS $LIBSEC/$f.c"
done
if ! $CC $CFLAGS $INC -o "$TMP/noncetest" "$D/noncetest.c" $SRCS "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: noncetest does not compile"
	exit 1
fi

fails=0
if ASAN_OPTIONS=detect_leaks=0 with_timeout 120 "$TMP/noncetest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: DSA and ElGamal sign with RFC 6979's nonce, hedged; a generator that repeats does not repeat one"
else
	head -40 "$TMP/out"
	echo "FAIL: noncetest"
	fails=1
fi

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ] && [ "$(uname)" = Linux ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
	exit $fails
fi
ccs="$CC"
command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
for cc in $ccs; do
	if ! $cc $PLAIN -DCTGRIND $INC -o "$TMP/noncetest-ct" "$D/noncetest.c" $SRCS "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: noncetest -DCTGRIND does not compile with $cc"
		exit 1
	fi
	for what in dsa dsaold eg; do
		log="$TMP/vg.$what"
		valgrind --error-limit=no --read-inline-info=yes --num-callers=30 --log-file="$log" "$TMP/noncetest-ct" ct $what "$D/vectors.txt" >"$TMP/ct.out" 2>&1
		st=$?
		if [ $st -ne 0 ]; then
			cat "$TMP/ct.out"
			echo "FAIL: $cc: noncetest ct $what did not make a signature that verifies"
			fails=$((fails+1))
			continue
		fi
		awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$log" | sort | uniq -c >"$TMP/fns"
		list="$(awk '{print $2}' "$TMP/fns" | tr '\n' ' ')"
		case $what in
		dsa)
			# public by design: the candidate's range, r and s zero, and
			# alpha^k mod p (which a verifier computes) divided by q
			# (mpnorm trims every result, wherever it is made)
			bad=$(awk '
				/depends on uninitialised|Use of uninitialised/ { if(inrep) flush(); inrep = 1; at = ""; deep = 0; next }
				inrep && /    at 0x/ { at = $0; sub(/.*: /, "", at); sub(/ \(.*/, "", at) }
				inrep && /mpextendedgcd|mpmultry|mpmuladdmod|montmul|montexp|mpexpmont|mptobe|betomp|mpnoncestart/ { deep = 1 }
				inrep && !/    (at|by) 0x/ { flush() }
				function flush() {
					if(at != "mpnorm" && (deep || at !~ /^(dsasignrnd|mpnoncenext|mpdivtry|mpdigdiv|mpveccmp|mpmagcmp|mpcmp|mpright|mpvecdigmulsub|mpvecadd)$/))
						print at
					inrep = 0
				}
				END { if(inrep) flush() }' "$log" | sort -u | tr '\n' ' ')
			if [ -n "$bad" ]; then
				echo "FAIL: $cc: dsasign: branches or addresses depend on the key or the nonce in:"
				sed 's/^/    /' "$TMP/fns"
				fails=$((fails+1))
			else
				echo "PASS: $cc: dsasign: nothing depends on the key or the nonce in the inversion or the products ($list: public decisions, and alpha^k mod p divided by q)"
			fi
			;;
		dsaold)
			if ! grep -q 'mpextendedgcd' "$TMP/fns"; then
				echo "FAIL: $cc: the check did not catch the arithmetic dsasign had"
				fails=$((fails+1))
			else
				echo "PASS: $cc: the check catches the arithmetic dsasign had ($list)"
			fi
			;;
		eg)
			if grep -q 'montmul\|montexp' "$log"; then
				echo "FAIL: $cc: egsign: the power alpha^k depends on the nonce"
				fails=$((fails+1))
			else
				echo "NOTE: $cc: egsign: reported, in libmp's general arithmetic mod p-1 on blinded numbers: $list"
			fi
			;;
		esac
	done
done
[ $fails -eq 0 ] && exit 0
exit 1
