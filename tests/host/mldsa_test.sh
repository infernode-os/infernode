#!/bin/bash
#
# tests/host/mldsa_test.sh
#
# libsec/mldsa*.c, ML-DSA-65 and -87 (FIPS 204) under Keyring's mldsa65
# and mldsa87 signature algorithms (Inferno certificates; the signer in
# CNSA mode), built on the host with tests/host/mldsa/dsatest.c:
#
#   - OpenSSL's answers (tests/host/mldsa/vectors.txt, made by gen.py
#     there): keys from the seed; ML-DSA.Sign (FIPS 204 Algorithm 2: the
#     pure signature, M' = 0 || |ctx| || ctx || M) with the randomness
#     given makes OpenSSL's signature byte for byte, with an empty
#     context string and with one, and Sign_internal (Algorithm 7) on M'
#     whole makes OpenSSL's; signing takes 32 fresh random bytes each
#     time and two signatures of one message differ; signatures verify,
#     and not once changed, under another context string, or as the
#     other interface's; a context string of more than 255 bytes is
#     refused; under ASan and UBSan too, in heap buffers exactly their
#     length.  (mldsa65_sign and mldsa87_sign used to be Sign_internal
#     on the caller's message: a signature on 00 00 || X was to every
#     conforming verifier the signature of X, and none made here
#     verified elsewhere.  rho'' used to be H(K || mu), with no rnd.)
#   - the rejection loop is bounded: built to allow one round, signing
#     gives up most of the time, with nothing written (it had no bound)
#   - where Python's cryptography package has ML-DSA, random keys,
#     messages and context strings against OpenSSL both ways, through
#     the package's own sign and verify
#
# No emulator is needed.
#
# Run from project root: ./tests/host/mldsa_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/mldsa"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC=""
for f in mldsa mldsa_poly mldsa_ntt sha3 securezero; do
	SRC="$SRC $ROOT/libsec/$f.c"
done
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -fcommon -w"
SAN="-g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -fno-strict-aliasing -fcommon -w"

fails=0

if ! $CC $CFLAGS $INC -o "$TMP/dsatest" "$D/dsatest.c" $SRC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: dsatest does not compile"
	exit 1
fi
if "$TMP/dsatest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/  /' "$TMP/out"
	echo "PASS: OpenSSL's known answers; signing is hedged; changed signatures refused"
else
	sed 's/^/  /' "$TMP/out"
	echo "FAIL: known answers"
	fails=$((fails+1))
fi

havesan=0
echo 'int main(void){return 0;}' >"$TMP/san.c"
if $CC $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1 && "$TMP/san"; then
	havesan=1
	if ! $CC $SAN $INC -o "$TMP/dsatest-san" "$D/dsatest.c" $SRC 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: dsatest does not compile with the sanitizers"
		exit 1
	fi
	if ASAN_OPTIONS=detect_leaks=1 "$TMP/dsatest-san" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		echo "PASS: no sanitizer report (ASan, UBSan, leaks)"
	else
		tail -30 "$TMP/out" | sed 's/^/  /'
		echo "FAIL: under ASan and UBSan"
		fails=$((fails+1))
	fi
else
	echo "SKIP: sanitizers (this compiler has none)"
fi

# the rejection loop's bound, with one round allowed (and nothing leaked
# by a signing that gives up, where the sanitizers are)
f="$CFLAGS"
[ $havesan = 1 ] && f="$SAN"
if ! $CC $f -DMLDSA_MAXROUNDS=1 $INC -o "$TMP/dsatest-1" "$D/dsatest.c" $SRC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: dsatest -DMLDSA_MAXROUNDS=1 does not compile"
	exit 1
fi
if ASAN_OPTIONS=detect_leaks=1 "$TMP/dsatest-1" rounds >"$TMP/out" 2>&1; then
	sed 's/^/  /' "$TMP/out"
	echo "PASS: the rejection loop gives up at its bound, with nothing written"
else
	tail -20 "$TMP/out" | sed 's/^/  /'
	echo "FAIL: the rejection loop's bound"
	fails=$((fails+1))
fi

# OpenSSL, live
if command -v python3 >/dev/null 2>&1; then
	python3 "$D/cross.py" "$TMP/dsatest" 30 >"$TMP/out" 2>&1
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
	echo "mldsa: ALL PASS"
	exit 0
fi
echo "mldsa: $fails FAILED"
exit 1
