#!/bin/bash
#
# tests/host/mlkem_test.sh
#
# libsec/mlkem*.c, ML-KEM-768 and -1024 (FIPS 203) under Keyring's
# mlkem768_* and mlkem1024_* (TLS's X25519MLKEM768, the hybrid key
# agreement of Inferno's authentication), built on the host with
# tests/host/mlkem/kemtest.c:
#
#   - OpenSSL's answers (tests/host/mlkem/vectors.txt, made by gen.py
#     there): key generation from the seeds d and z (it hashed G(d) where
#     FIPS 203 Algorithm 13 hashes G(d || k), so a key from a seed was not
#     the standard's), OpenSSL's ciphertexts decapsulated, changed ones to
#     J(z || c); encapsulation; the input checks of 7.2 and 7.3; under
#     ASan and UBSan too, in heap buffers exactly their length
#   - constant time (ctgrind): with valgrind, key generation, an
#     encapsulation and a decapsulation of a good and of a changed
#     ciphertext are run with their secrets marked undefined, compiled by
#     gcc and by clang, at the emulator's -O and the native kernels' -O2;
#     memcheck reports any branch or address depending on them.  None is
#     allowed but the rejection sampling of the public matrix in key
#     generation (rho is public, though it comes from the seed).  clang
#     had turned decapsulation's masked choice between the secret and the
#     rejection value into a choice between two addresses.
#   - where Python's cryptography package has ML-KEM, random keys against
#     OpenSSL, each side decapsulating the other's ciphertexts
#
# The constant-time check needs valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/mlkem_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/mlkem"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC=""
for f in mlkem mlkem_poly mlkem_ntt sha3 securezero; do
	SRC="$SRC $ROOT/libsec/$f.c"
done
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -fcommon -w"
SAN="-g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -fno-strict-aliasing -fcommon -w"

fails=0

if ! $CC $CFLAGS $INC -o "$TMP/kemtest" "$D/kemtest.c" $SRC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: kemtest does not compile"
	exit 1
fi
if "$TMP/kemtest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/  /' "$TMP/out"
	echo "PASS: OpenSSL's known answers, encapsulation, key checks"
else
	sed 's/^/  /' "$TMP/out"
	echo "FAIL: known answers"
	fails=$((fails+1))
fi

echo 'int main(void){return 0;}' >"$TMP/san.c"
if $CC $SAN -o "$TMP/san" "$TMP/san.c" >/dev/null 2>&1 && "$TMP/san"; then
	if ! $CC $SAN $INC -o "$TMP/kemtest-san" "$D/kemtest.c" $SRC 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: kemtest does not compile with the sanitizers"
		exit 1
	fi
	if ASAN_OPTIONS=detect_leaks=1 "$TMP/kemtest-san" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		echo "PASS: no sanitizer report (ASan, UBSan, leaks)"
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
	# each compiler here, at the emulator's flags and the kernels': they
	# differ in what they make of a masked select
	ccs="$CC"
	command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
	for cc in $ccs; do
		for opt in -O -O2; do
			$cc -g $opt -fno-strict-aliasing -fcommon -w -DCTGRIND $INC -o "$TMP/kemtest-ct" "$D/kemtest.c" $SRC || { echo "FAIL: kemtest -DCTGRIND does not compile with $cc $opt"; exit 1; }
			bad=""
			n=0
			for set in 768 1024; do
				for what in keygen enc good bad; do
					valgrind --error-limit=no --read-inline-info=yes --log-file="$TMP/vg" "$TMP/kemtest-ct" ct $set $what >/dev/null 2>&1 || bad="$bad $set/$what:failed"
					# the function each report is in
					awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$TMP/vg" | sort | uniq -c >"$TMP/fns"
					case $what in
					keygen)	b=$(awk '{print $2}' "$TMP/fns" | grep -v -x 'mlkem_poly_sample_ntt') ;;
					*)	b=$(awk '{print $2}' "$TMP/fns") ;;
					esac
					[ -n "$b" ] && bad="$bad $set/$what:$(echo $b | tr ' ' ',')"
					n=$((n + $(awk '{n+=$1} END {print n+0}' "$TMP/fns")))
				done
			done
			if [ -n "$bad" ]; then
				echo "FAIL: $cc $opt: branches or addresses depend on a secret in:$bad"
				fails=$((fails+1))
			else
				echo "PASS: $cc $opt: key generation, encapsulation, decapsulation constant time ($n public decisions, the matrix's sampling)"
			fi
		done
	done
fi

# OpenSSL, live
if command -v python3 >/dev/null 2>&1; then
	python3 "$D/cross.py" "$TMP/kemtest" 20 >"$TMP/out" 2>&1
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
	echo "mlkem: ALL PASS"
	exit 0
fi
echo "mlkem: $fails FAILED"
exit 1
