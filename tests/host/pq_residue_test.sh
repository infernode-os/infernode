#!/bin/bash
#
# tests/host/pq_residue_test.sh
#
# What libsec's ML-KEM, ML-DSA and SLH-DSA leave of their secrets on the
# C stack once they have returned (tests/host/pqresidue/residue.c): each
# operation is run in a frame of its own with known seeds, the dead
# stack below is copied, and it is searched for
#
#   ML-KEM   sigma (the seed of s and e), the bits a noise polynomial
#            was made of, the Keccak state of J(z || c), d and z
#   ML-DSA   K and rho' (the secret key's seeds), the half bytes a secret
#            polynomial was made of, rho'' (the seed of a signature's
#            masks), a mask's bytes, the signing randomness, xi
#   SLH-DSA  SK.seed and SK.prf
#
# None may be found.  The code cleared its named copies of the seeds and
# left the buffer they were cut from, the samplers' buffers and every
# SHAKE state (Keccak's permutation runs backwards, so a state that
# absorbed a seed is the seed): sigma, K, rho' and the state of
# J(z || c) were there to be read by whatever else reads dead stack.
#
# Built by each compiler here at the emulator's -O and the kernels' -O2,
# and linked with the dynamic linker binding at load: its lazy resolver
# saves the vector registers on the stack at a function's first call,
# and a compiler copies 32 bytes through them.  That, like a register
# spilled by an interrupt, is beyond what C can clear; the test is of
# what the code leaves in its own variables.
#
# Run from project root: ./tests/host/pq_residue_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/pqresidue"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
SRC=""
for f in mlkem mlkem_poly mlkem_ntt mldsa mldsa_poly mldsa_ntt slhdsa slhdsa_fors slhdsa_wots slhdsa_tree slhdsa_hash sha3 securezero; do
	SRC="$SRC $ROOT/libsec/$f.c"
done

fails=0
ccs="$CC"
command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
for cc in $ccs; do
	# bind at load, however this linker spells it
	now=""
	echo 'int main(void){return 0;}' >"$TMP/p.c"
	for f in -Wl,-z,now -Wl,-bind_at_load; do
		if $cc $f -o "$TMP/p" "$TMP/p.c" >/dev/null 2>&1; then
			now=$f
			break
		fi
	done
	for opt in -O -O2; do
		if ! $cc -g $opt -fno-strict-aliasing -fcommon -w $now $INC -o "$TMP/residue" "$D/residue.c" $SRC 2>"$TMP/cc.log"; then
			cat "$TMP/cc.log"
			echo "FAIL: residue.c does not compile with $cc $opt"
			exit 1
		fi
		if "$TMP/residue" >"$TMP/out" 2>&1; then
			echo "PASS: $cc $opt: $(tail -1 "$TMP/out")"
		else
			sort "$TMP/out" | uniq -c | sed 's/^ */    /'
			echo "FAIL: $cc $opt: secrets left on the stack"
			fails=$((fails+1))
		fi
	done
done

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "pq_residue: ALL PASS"
	exit 0
fi
echo "pq_residue: $fails FAILED"
exit 1
