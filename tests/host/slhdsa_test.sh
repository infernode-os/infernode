#!/bin/bash
#
# tests/host/slhdsa_test.sh
#
# libsec/slhdsa*.c, SLH-DSA-SHAKE-192s and -256s (FIPS 205) under
# Keyring's slhdsa192s and slhdsa256s signature algorithms, built on the
# host with tests/host/slhdsa/slhtest.c:
#
#   - known answers (tests/host/slhdsa/vectors.txt, made by gen.py there
#     from slh_ref.py, FIPS 205 written out in Python, and equal byte for
#     byte to OpenSSL's): key generation from the three seeds, the pure
#     deterministic signature with an empty context string, a signature
#     made elsewhere verified
#   - what is not such a signature refused: the format this code made
#     before it was held to the standard (its WOTS+ checksum kept only
#     its low byte, the tree and leaf index were other bits of the
#     digest, the FORS key pair address was always 0, and the message was
#     signed without M's header), the internal interface, a context
#     string, signatures cut, lengthened or with a bit changed, in heap
#     buffers exactly their length under ASan and UBSan
#   - a WOTS+ signature chained forward to a message with digits raised
#     by 256 is not the key's signature (it was: only the checksum mod
#     256 was signed), alone and under an XMSS root
#   - where OpenSSL's SLH-DSA can be reached from Python (ossl.py: the
#     OpenSSL inside the cryptography package), random keys and messages
#     against it both ways
#
# No emulator is needed.  The sanitizers' part is skipped where the
# compiler has none.
#
# Run from project root: ./tests/host/slhdsa_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/slhdsa"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC=""
for f in slhdsa slhdsa_fors slhdsa_wots slhdsa_tree slhdsa_hash securezero; do
	SRC="$SRC $ROOT/libsec/$f.c"
done
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -fcommon -w"
SAN="-g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -fno-strict-aliasing -fcommon -w"

fails=0

# SHAKE is not what is tested here and is nearly all of the time (a
# signature is three million hashes): it is built once, as fast as the
# compiler makes it and without the sanitizers, for both programs
if ! $CC -O3 -fno-strict-aliasing -fcommon -w $INC -c -o "$TMP/sha3.o" "$ROOT/libsec/sha3.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: sha3.c does not compile"
	exit 1
fi
SRC="$SRC $TMP/sha3.o"

if ! $CC $CFLAGS $INC -o "$TMP/slhtest" "$D/slhtest.c" $SRC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: slhtest does not compile"
	exit 1
fi

if "$TMP/slhtest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/  /' "$TMP/out"
	echo "PASS: FIPS 205 known answers; other formats, lengths and changed signatures refused"
else
	sed 's/^/  /' "$TMP/out"
	echo "FAIL: known answers"
	fails=$((fails+1))
fi

if "$TMP/slhtest" forge >"$TMP/out" 2>&1; then
	sed 's/^/  /' "$TMP/out"
	echo "PASS: a WOTS+ signature chained forward is not a signature"
else
	sed 's/^/  /' "$TMP/out"
	echo "FAIL: a WOTS+ signature chained forward to another message is accepted"
	fails=$((fails+1))
fi

# the same under the sanitizers: one known answer a set, every signature
# from elsewhere at its lengths
echo 'int main(void){return 0;}' >"$TMP/san.c"
if $CC $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1 && "$TMP/san"; then
	if ! $CC $SAN $INC -o "$TMP/slhtest-san" "$D/slhtest.c" $SRC 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: slhtest does not compile with the sanitizers"
		exit 1
	fi
	if ASAN_OPTIONS=detect_leaks=1 "$TMP/slhtest-san" "$D/vectors.txt" quick >"$TMP/out" 2>&1; then
		echo "PASS: no sanitizer report (ASan, UBSan, leaks) in key generation, signing and verifying"
	else
		tail -30 "$TMP/out" | sed 's/^/  /'
		echo "FAIL: under ASan and UBSan"
		fails=$((fails+1))
	fi
else
	echo "SKIP: sanitizers (this compiler has none)"
fi

# OpenSSL, live
if command -v python3 >/dev/null 2>&1; then
	python3 "$D/cross.py" "$TMP/slhtest" 1 >"$TMP/out" 2>&1
	rc=$?
	if [ $rc -eq 0 ]; then
		echo "PASS: $(tail -1 "$TMP/out")"
	elif [ $rc -eq 77 ]; then
		cat "$TMP/out"
	else
		sed 's/^/  /' "$TMP/out"
		echo "FAIL: libsec and OpenSSL disagree"
		fails=$((fails+1))
	fi
else
	echo "SKIP: OpenSSL cross-check (no python3)"
fi

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "slhdsa: ALL PASS"
	exit 0
fi
echo "slhdsa: $fails FAILED"
exit 1
