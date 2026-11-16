#!/bin/bash
#
# tests/host/rsa_edge_test.sh
#
# libsec's RSA (rsaencrypt.c, rsadecrypt.c, rsafill.c, rsagen.c) on the
# host under AddressSanitizer (tests/host/rsa_edge/rsatest.c), with a
# 2048-bit key, a representative and its signature from OpenSSL
# (tests/host/rsa_edge/vectors.txt, made by gen.py):
#
#   - a representative outside 0..n-1 has no result (RFC 8017 5.1.1,
#     5.1.2, 5.2.1, 5.2.2 step 1): s+n and s-n verified as s, m+n and
#     m-n were signed as m
#   - rsadecrypt checks its result before giving it out: with kp, kq or
#     c2 not the key's (a damaged key file, a fault) it returned a number
#     right mod one prime and wrong mod the other, from which
#     gcd(s^e - m, n) is a prime of the key
#   - rsafill with p == q is nil (mpinvert raised with two numbers made
#     and nothing to free them: 768 bytes of the kernel's pool a call
#     from RSAsk.fill), with a negative part nil (a raise, or a key every
#     use of which raised)
#   - rsagen's d is the least positive inverse of e (it was negative for
#     one key in ten, and rsafill refused such a key), 150 keys
#
# No emulator is needed.
#
# Run from project root: ./tests/host/rsa_edge_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/rsa_edge"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo 'int main(void){return 0;}' > "$TMP/san.c"
if ! $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null || ! "$TMP/san"; then
	echo "SKIP: $CC has no AddressSanitizer here"
	exit 77
fi

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
CFLAGS="-g -O -fno-strict-aliasing -w -fsanitize=address,undefined -fno-sanitize-recover=undefined"
# (RSA_SRC: a directory with another libsec's sources, to see what they do)
LIBSEC="${RSA_SRC:-$ROOT/libsec}"
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod mpexp mpextendedgcd mpinvert \
	betomp letomp mptobe mprand mptoi mptoui mpfmt strtomp; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done
for f in rsaencrypt rsadecrypt rsafill rsaalloc rsagen probably_prime smallprimetest genprime; do
	SRCS="$SRCS $LIBSEC/$f.c"
done

objs=""
for s in $SRCS; do
	o="$TMP/$(basename "$s" .c).o"
	if ! $CC $CFLAGS -Dmalloc=xmalloc -Dfree=xfree $INC -c -o "$o" "$s" 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: $s does not compile"
		exit 1
	fi
	objs="$objs $o"
done
if ! $CC $CFLAGS $INC -o "$TMP/rsatest" "$D/rsatest.c" $objs "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: rsatest does not compile"
	exit 1
fi

if ASAN_OPTIONS=detect_leaks=0 with_timeout 120 "$TMP/rsatest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: RSA's ranges, its checked result, rsafill's refusals and rsagen's d"
	exit 0
fi
grep -v "p == q = 11" "$TMP/out" | head -40
echo "FAIL: rsatest"
exit 1
