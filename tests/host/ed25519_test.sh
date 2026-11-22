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
# Then the arithmetic on secrets, which was not constant time: [a]B (a
# the secret scalar, or a signature's nonce) was double-and-add with
# the addition made only for a's set bits, and S = (r + h*a) mod L was
# libmp's multiplication and division.  Both are fixed sequences now:
#   - sc_muladd and sc_reduce against libmp's arithmetic, and [a]B
#     against plain double-and-add, on 20000 random and extreme values
#     (0, 1, L-1, L, L+1, all ones), in the same sanitized program
#   - constant time (ctgrind): with valgrind, a signature and a public
#     key are made of a seed marked undefined, so the scalar and the
#     nonce made of it are; valgrind reports every branch and every
#     address that depends on them, and there must be none.  The code
#     before is reported in ge_scalarmult_base and in libmp.
# The constant-time check needs valgrind (Linux); CI installs it, and
# a CI run without it fails rather than skips.  EDTEST_CFLAGS adds
# compiler flags: the code before is run through this with
# -Dsc_muladd=sc_muladd_simple, its name for S's arithmetic.
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
# edtest.c includes libkeyring/ed25519alg.c itself
SRCS="$S/securezero.c $S/sha2.c $S/sha256block.c $S/sha256arm64.c $S/sha512block.c"
# libmp: Keyring's glue converts a number to sign, and the test checks the scalar arithmetic against it
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
		if ! $cc -g $opt -fno-strict-aliasing -w $SAN $EDTEST_CFLAGS $INC -o "$TMP/edtest" "$D/edtest.c" $SRCS 2>"$TMP/cc.log"; then
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

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ] && [ "$(uname)" = Linux ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
	exit $rc
fi
# each compiler here, at each level: they differ in what they make of a masked select
for cc in $ccs; do
	for opt in -O -O2; do
		if ! $cc -g $opt -fno-strict-aliasing -w -DCTGRIND $EDTEST_CFLAGS $INC -o "$TMP/edtest-ct" "$D/edtest.c" $SRCS 2>"$TMP/cc.log"; then
			echo "FAIL: $cc $opt: edtest -DCTGRIND does not build"
			head -20 "$TMP/cc.log"
			rc=1
			continue
		fi
		for what in sign pubkey; do
			valgrind --error-limit=no --read-inline-info=yes --log-file="$TMP/vg" "$TMP/edtest-ct" ct "$what" >"$TMP/out" 2>&1
			st=$?
			# the function each report is in
			awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$TMP/vg" | sort | uniq -c >"$TMP/fns"
			if [ $st -ne 0 ]; then
				echo "FAIL: $cc $opt: $what did not run under valgrind (status $st)"
				tail -5 "$TMP/vg"
				rc=1
			elif [ -s "$TMP/fns" ]; then
				echo "FAIL: $cc $opt: $what: branches or addresses depend on the secret scalar or the nonce in:"
				sed 's/^/    /' "$TMP/fns"
				rc=1
			else
				echo "PASS: $cc $opt: $what constant time (valgrind: no branch or address on the seed, the scalar or the nonce)"
			fi
		done
	done
done
exit $rc
