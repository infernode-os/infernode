#!/bin/bash
#
# tests/host/ecc_test.sh
#
# libsec/ecc.c, the P-256 and P-384 arithmetic under keyring's
# p256_*/p384_* (TLS key shares, ECDSA certificates), built on the host
# with tests/host/ecc/ecctest.c:
#
#   - known answers from OpenSSL (tests/host/ecc/vectors.txt, made by
#     tests/host/ecc/gen.py): d*G for small, large and random d, ECDH,
#     OpenSSL's ECDSA signatures verified and changed ones refused
#   - the complete addition formulas' edge cases, keygen and ECDH round
#     trips, sign then verify, invalid peer points refused
#   - constant time (ctgrind): with valgrind, each operation is run with its
#     secret scalar (or the random numbers it makes: nonce, new key) marked
#     undefined; memcheck reports any branch or address depending on it.
#     Scalar multiplication must give no report; the rest only in the
#     decisions that are public by design: a random candidate out of range
#     rejected (randscalar), a result that is the identity (ptaffine), a
#     public key checked on the curve (ptload), r or s zero (ecdsasign,
#     both published in the signature).  With clang, the identity check
#     inlined into ecdh is reported there too (ecdh, ten lines, has no
#     other test of a secret)
#
# CC=clang checks clang's code: it turned masked selects back into
# branches until the masks went through a barrier (libsec/ecc.c bitmask).
#
# The constant-time check needs valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/ecc_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/ecc"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -w"

fails=0

if ! $CC $CFLAGS $INC -o "$TMP/ecctest" "$D/ecctest.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: ecctest does not compile"
	exit 1
fi
if "$TMP/ecctest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	cat "$TMP/out"
	echo "PASS: known answers, edge cases, round trips, invalid points"
else
	cat "$TMP/out"
	echo "FAIL: ecctest"
	fails=$((fails+1))
fi

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
else
	# each compiler here: macOS builds with clang, Linux with gcc, and
	# they differ in what they make of a masked select
	ccs="$CC"
	command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
	for cc in $ccs; do
		$cc $CFLAGS -DCTGRIND $INC -o "$TMP/ecctest-ct" "$D/ecctest.c" || { echo "FAIL: ecctest -DCTGRIND does not compile with $cc"; exit 1; }
		for what in ptmul256 ptmul384 ecdh256 ecdh384 keygen256 keygen384 sign256; do
			valgrind --error-limit=no --read-inline-info=yes --log-file="$TMP/vg.$what" "$TMP/ecctest-ct" ct "$what" >/dev/null 2>&1
			# the function each report is in
			awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$TMP/vg.$what" | sort | uniq -c >"$TMP/fns.$what"
			bad=$(awk '{print $2}' "$TMP/fns.$what" | grep -v -x 'randscalar\|ptaffine\|ptload\|ecdsasign\|ecdh')
			case $what in ptmul*) bad=$(awk '{print $2}' "$TMP/fns.$what") ;; esac
			if [ -n "$bad" ]; then
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
	echo "ecc: ALL PASS"
	exit 0
fi
echo "ecc: $fails FAILED"
exit 1
