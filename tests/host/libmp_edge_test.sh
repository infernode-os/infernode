#!/bin/bash
#
# tests/host/libmp_edge_test.sh
#
# libmp's sizes, signs and text, on the host under AddressSanitizer and
# UndefinedBehaviorSanitizer (tests/host/libmp_edge/mpedge.c):
#
#   - a size is an int of bits, and the sums that make one were ints:
#     mpbits took a count that had wrapped for room enough, and the
#     digits were stored past the block.  mpbits and mpnew refuse a count
#     that is negative or past what a number may have; the product of the
#     longest number by a digit, the longest number plus one, a shift to
#     the largest int, and bytes whose bits pass an int (betomp, letomp)
#     are refused before a digit is touched
#   - base 32 read with base 32's own digits; a length base 32 does not
#     have (1, 3 or 6 past a multiple of 8) is no number (the decoder's -1
#     was given to betomp as a count of bytes); written with the bytes of
#     zero in front (1, 256 and 65536 were one text)
#   - "-0" is zero; base 64 into a buffer too short is refused, not cut;
#     no memory for the decoded bytes is no number
#   - mprand with no memory raises (it returned nil, leaving a zero the
#     callers went on to use), and leaves no digit of a longer number
#   - mpdiv's signs (6/3 into a number that had held -5 was -2; a
#     quotient written over the dividend gave the remainder its sign), one
#     number for both results refused; mpmod with a negative modulus, and
#     into the modulus; b^0 mod 1 is 0; zero digits above an exponent or
#     a modulus (a loop for ever, a store past the limbs); a zero written
#     with digits to the gcd (for ever)
#   - a product is made without Karatsuba's scratch when there is no
#     memory for it (the raise left every level's scratch behind)
#   - 3000 divisions and remainders of mixed signs, and 3300 numbers
#     written and read in bases 10, 16, 32 and 64, against Python's
#     (tests/host/libmp_edge/vectors.txt, made by gen.py)
#
# No emulator is needed.
#
# Run from project root: ./tests/host/libmp_edge_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/libmp_edge"
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
# (MPEDGE_CFLAGS: more flags, to look past the first report of an older libmp)
CFLAGS="-g -O -fno-strict-aliasing -w -fsanitize=address,undefined -fno-sanitize-recover=undefined $MPEDGE_CFLAGS"
LIBMP="${LIBMP_SRC:-$ROOT/libmp}"
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod mpexp mpextendedgcd \
	betomp letomp mptobe mprand mptoi mptoui mpfmt strtomp; do
	SRCS="$SRCS $LIBMP/$f.c"
done

# libmp's malloc and free are the test's; lib9's decoders as they are
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
if ! $CC $CFLAGS $INC -o "$TMP/mpedge" "$D/mpedge.c" $objs "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: mpedge does not compile"
	exit 1
fi

# what libmp held when it raised is not given back (it has no handler): no leak check
# (MPEDGE_ONLY: one section alone, to see what an older libmp does on each)
if ASAN_OPTIONS=detect_leaks=0 with_timeout 120 "$TMP/mpedge" "$D/vectors.txt" $MPEDGE_ONLY >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: libmp sizes, signs and text under ASan and UBSan"
	exit 0
fi
head -40 "$TMP/out"
echo "FAIL: mpedge"
exit 1
