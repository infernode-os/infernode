#!/bin/sh
# libkeyring/ed25519alg.c's Ed25519 (the ref10 arithmetic) on the host,
# with the undefined-behaviour sanitizer.
#
# ref10 takes a carry out of a signed limb and subtracts it back with
# "h -= carry << 25", and a carry is negative half the time: a left
# shift of a negative value, which C does not define (the sanitizer's
# emulator reported it in every signature made).  The compilers in use
# shift all the same; one that reasons from "carry is not negative"
# need not.  Each is now a multiplication by the power of two.
#
# Known answers from Python's cryptography (tests/host/ed25519/gen.py;
# vectors.txt is kept, so nothing is needed at run time but a C
# compiler): RFC 8032 7.1's first three keys and 120 more, messages of
# 0 to 307 bytes: the public key, the signature byte for byte, and
# refusals (R, S, the message or the key changed; the order added to
# S).  Built with -fsanitize=undefined, where a report ends the
# program, at -O (as the emulator's libraries are) and -O2, with cc and
# with clang where there is one.  No emulator is needed.
#
# Run from project root: ./tests/host/ed25519_test.sh

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/ed25519"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libinterp -I$ROOT/libkeyring -I$ROOT/libmp"
S="$ROOT/libsec"
SRCS="$ROOT/libkeyring/ed25519alg.c $S/securezero.c $S/sha2.c $S/sha256block.c $S/sha256arm64.c $S/sha512block.c"
# the signature's S is (r + h*a) mod L by libmp
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod betomp mptobe; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done
SAN="-fsanitize=undefined -fno-sanitize-recover=undefined"

echo 'int main(void){return 0;}' > "$TMP/san.c"
if ! $CC $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1 || ! "$TMP/san"; then
	echo "SKIP: $CC has no undefined-behaviour sanitizer"
	exit 77
fi

rc=0
ccs="$CC"
command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
for cc in $ccs; do
	# a compiler with no sanitizer runtime to link (clang without compiler-rt) is passed over
	if ! $cc $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1; then
		echo "note: $cc has no undefined-behaviour sanitizer here; not used"
		continue
	fi
	for opt in -O -O2; do
		if ! $cc -g $opt -fno-strict-aliasing -w $SAN $INC -o "$TMP/edtest" "$D/edtest.c" $SRCS 2>"$TMP/cc.log"; then
			echo "FAIL: $cc $opt: does not build"
			head -20 "$TMP/cc.log"
			rc=1
			continue
		fi
		if "$TMP/edtest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
			echo "PASS: $cc $opt: $(tail -1 "$TMP/out"), nothing undefined"
		else
			echo "FAIL: $cc $opt: $(grep -c 'runtime error' "$TMP/out") sanitizer reports"
			grep 'runtime error\|FAIL' "$TMP/out" | sort | uniq -c | head -8
			tail -2 "$TMP/out"
			rc=1
		fi
	done
done
exit $rc
