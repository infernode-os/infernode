#!/bin/bash
#
# tests/host/acvp_pq_test.sh
#
# NIST's ACVP vectors for ML-KEM (FIPS 203), ML-DSA (FIPS 204) and
# SLH-DSA (FIPS 205) against libsec/mlkem*.c, mldsa*.c and slhdsa*.c,
# built on the host with tests/host/acvp/acvptest.c: key generation from
# the seeds; ML-KEM encapsulation with m given, decapsulation (a changed
# ciphertext gives the implicit rejection's key) and the two key checks;
# ML-DSA and SLH-DSA signing and verifying through the external
# interface (pure, with and without a context string, hedged with NIST's
# randomness and deterministic) and the internal one (ML-DSA with the
# message and with mu), every reason NIST gives for a signature to be
# refused.  The parameter sets are the ones libsec has: ML-KEM-768 and
# -1024, ML-DSA-65 and -87, SLH-DSA-SHAKE-192s and -256s.
#
# tests/host/acvp/vectors.txt.gz is a part of NIST's files, cut by
# tests/host/acvp/reduce.py -k (which says how): 237 cases of the 612 in
# the groups run.  With ACVP_DIR naming a directory of NIST's files
# (github.com/usnistgov/ACVP-Server, gen-val/json-files: one directory
# an algorithm and mode, each with its internalProjection.json) every
# case of those groups is run instead, which takes some minutes; that
# was done when the part was cut, and all 612 passed.
#
# Not run, for want of an entry point in libsec, and none is wanted:
# the pre-hash signatures (HashML-DSA and HashSLH-DSA, FIPS 204 section
# 5.4 and FIPS 205 section 10.2), which nothing here signs with:
# Keyring's certificates are the pure signature of a digest it makes.
#
# No emulator is needed.  Skips without gzip (or, with ACVP_DIR,
# python3).
#
# Run from project root: ./tests/host/acvp_pq_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/acvp"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC=""
for f in mlkem mlkem_poly mlkem_ntt mldsa mldsa_poly mldsa_ntt slhdsa slhdsa_fors slhdsa_wots slhdsa_tree slhdsa_hash sha3 securezero; do
	SRC="$SRC $ROOT/libsec/$f.c"
done
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -fcommon -w"

if ! $CC $CFLAGS $INC -o "$TMP/acvptest" "$D/acvptest.c" $SRC 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: acvptest does not compile"
	exit 1
fi

if [ -n "${ACVP_DIR:-}" ]; then
	command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3 to read NIST's files"; exit 77; }
	# NIST's files are data: read by a script that is not among them, with -I
	if ! python3 -I "$D/reduce.py" "$ACVP_DIR" >"$TMP/cases" 2>"$TMP/notrun"; then
		cat "$TMP/notrun"
		echo "FAIL: reduce.py could not read $ACVP_DIR"
		exit 1
	fi
	sed 's/^/  /' "$TMP/notrun"
	what="every case of NIST's files"
else
	command -v gzip >/dev/null 2>&1 || { echo "SKIP: no gzip"; exit 77; }
	gzip -dc "$D/vectors.txt.gz" >"$TMP/cases" || { echo "FAIL: cannot read $D/vectors.txt.gz"; exit 1; }
	what="the cases kept in the tree"
fi

"$TMP/acvptest" <"$TMP/cases" >"$TMP/out" 2>&1
rc=$?
sed 's/^/  /' "$TMP/out"
echo "----"
if [ $rc -eq 0 ]; then
	echo "acvp_pq: ALL PASS ($what)"
	exit 0
fi
echo "acvp_pq: FAILED ($what)"
exit 1
