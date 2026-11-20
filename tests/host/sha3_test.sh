#!/bin/bash
#
# tests/host/sha3_test.sh
#
# libsec/sha3.c: SHA3-256, SHA3-512, SHAKE128 and SHAKE256 (FIPS 202),
# which ML-KEM, ML-DSA and SLH-DSA are made of, built on the host with
# tests/host/sha3/sha3test.c:
#
#   - hashlib's answers (tests/host/sha3/vectors.txt, made by gen.py
#     there): lengths either side of every rate, the SHAKEs in one call
#     and absorbed and squeezed in pieces; 1200 random messages against
#     a sponge written from the standard; under ASan and UBSan too, and
#     with each compiler here
#   - calls out of turn do what libsec.h says: a squeeze with no
#     finalize finalizes first, an absorb after a finalize takes nothing
#     (they mixed bytes into the state wherever squeezing had reached,
#     and squeezed the state of an unpadded input)
#   - Keccak-f at the emulator's flags (-O) is at least twice as fast as
#     the loops it was written as (indices mod 5, rotations from a
#     table), which a compiler asked for little left as written: two
#     microseconds a permutation, and an SLH-DSA signature, three million
#     of them, 9 s in the emulator.  Both are timed here, turn about
#   - with valgrind, constant time (ctgrind): a secret message through
#     every function, no branch or address depending on it
#
# No emulator is needed.
#
# Run from project root: ./tests/host/sha3_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/sha3"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC="$ROOT/libsec/sha3.c $ROOT/libsec/securezero.c"
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -fcommon -w"
SAN="-g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -fno-strict-aliasing -fcommon -w"

fails=0

ccs="$CC"
command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
for cc in $ccs; do
	if ! $cc $CFLAGS $INC -o "$TMP/sha3test" "$D/sha3test.c" $SRC 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: sha3test does not compile with $cc"
		exit 1
	fi
	if "$TMP/sha3test" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		echo "PASS: $cc: $(tail -1 "$TMP/out")"
	else
		sed 's/^/  /' "$TMP/out"
		echo "FAIL: $cc: known answers"
		fails=$((fails+1))
	fi
	if "$TMP/sha3test" time >"$TMP/out" 2>&1; then
		echo "PASS: $cc -O: $(tail -1 "$TMP/out")"
	else
		sed 's/^/  /' "$TMP/out"
		echo "FAIL: $cc -O: Keccak-f's speed"
		fails=$((fails+1))
	fi
done

echo 'int main(void){return 0;}' >"$TMP/san.c"
if $CC $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1 && "$TMP/san"; then
	if ! $CC $SAN $INC -o "$TMP/sha3test-san" "$D/sha3test.c" $SRC 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: sha3test does not compile with the sanitizers"
		exit 1
	fi
	if "$TMP/sha3test-san" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		echo "PASS: no sanitizer report (ASan, UBSan)"
	else
		tail -30 "$TMP/out" | sed 's/^/  /'
		echo "FAIL: under ASan and UBSan"
		fails=$((fails+1))
	fi
else
	echo "SKIP: sanitizers (this compiler has none)"
fi

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
else
	for cc in $ccs; do
		for o in -O -O2; do
			$cc -g $o -fno-strict-aliasing -fcommon -w -DCTGRIND $INC -o "$TMP/sha3test-ct" "$D/sha3test.c" $SRC || { echo "FAIL: sha3test -DCTGRIND does not compile with $cc"; exit 1; }
			valgrind --error-limit=no --error-exitcode=9 --log-file="$TMP/vg" "$TMP/sha3test-ct" ct >/dev/null 2>&1
			rc=$?
			n=$(grep -c 'depends on uninitialised\|Use of uninitialised' "$TMP/vg")
			if [ $rc -ne 0 ] || [ "$n" -ne 0 ]; then
				grep -A6 'depends on uninitialised\|Use of uninitialised' "$TMP/vg" | head -30 | sed 's/^/    /'
				echo "FAIL: $cc $o: branches or addresses depend on the message"
				fails=$((fails+1))
			else
				echo "PASS: $cc $o: constant time"
			fi
		done
	done
fi

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "sha3: ALL PASS"
	exit 0
fi
echo "sha3: $fails FAILED"
exit 1
