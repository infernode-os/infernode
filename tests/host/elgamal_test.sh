#!/bin/bash
#
# tests/host/elgamal_test.sh
#
# libsec's ElGamal signatures (egverify.c, eggen.c, egsign.c) on the host
# under AddressSanitizer (tests/host/elgamal/egtest.c).
#
# eggen(2048) took RFC 3526's group 14 with its generator 2, which
# divides p-1, and egverify asked of r only that it lie from 1 to p-1:
# with r = (p-1)/2 and an even s chosen from the message a signature
# verified for any message under any such key, from the public key
# alone (Bleichenbacher, Eurocrypt 1996).  A generator of 4, which does
# not divide p-1, was forged with the same r.
#
#   - 20 random messages forged that way under a key with generator 2
#     and under one with generator 4: none verifies (all did)
#   - a key is valid only with a generator and public value of order
#     (p-1)/2 and a generator that does not divide p-1: generator 2 and
#     a generator of the whole group are refused, generator 4 is a key
#   - r = p-1 refused; s from 1 to p-2 (s + (p-1) verified); r from 1 to
#     p-1; another message refused
#   - eggen at 2048, 256 and 3 to 12 bits: valid keys on safe primes
#     with a secret in range, which sign and verify, and under which
#     neither forgery verifies
#
# No emulator is needed.
#
# Run from project root: ./tests/host/elgamal_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/elgamal"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

CFLAGS="-g -O -fno-strict-aliasing -w"
echo 'int main(void){return 0;}' > "$TMP/san.c"
if $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null && "$TMP/san"; then
	CFLAGS="$CFLAGS -fsanitize=address,undefined -fno-sanitize-recover=undefined"
fi
INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod mpexp mpextendedgcd mpinvert \
	betomp letomp mptobe mprand mptoi mptoui mpfmt strtomp; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done
for f in egverify eggen egsign egalloc dhparams gensafeprime genprime probably_prime smallprimetest \
	nonce mpnonce hmac sha1 sha1block sha2 sha256block sha256arm64 sha512block md5 md5block securezero; do
	SRCS="$SRCS $ROOT/libsec/$f.c"
done
if ! $CC $CFLAGS $INC -o "$TMP/egtest" "$D/egtest.c" $SRCS "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: egtest does not compile"
	exit 1
fi
if ASAN_OPTIONS=detect_leaks=0 with_timeout 300 "$TMP/egtest" >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: ElGamal signatures are not forged from a public key; keys are ones the forgery has no hold on"
	exit 0
fi
head -30 "$TMP/out"
echo "FAIL: egtest"
exit 1
