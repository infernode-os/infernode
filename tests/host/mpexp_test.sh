#!/bin/bash
#
# tests/host/mpexp_test.sh
#
# libmp/mpexp.c, modular exponentiation under IPint.expmod (Inferno
# authentication's Diffie-Hellman, secstore), RSA, DSA and ElGamal,
# built on the host with tests/host/mpexp/mptest.c:
#
#   - known answers from Python's pow (tests/host/mpexp/vectors.txt, made
#     by tests/host/mpexp/gen.py): moduli of 1 to 4096 bits, either side of
#     each limb boundary, bases 0, 1, m-1, m and above m, exponents whose
#     windows are all zero or all ones, even moduli (the general path);
#     each also through the general path and with the result in place of
#     each operand
#   - random operands: the Montgomery path against the general path
#   - both limb widths: 64 (where the compiler has a 128-bit product) and
#     32 (MPEXP32: MSVC, 32-bit hosts)
#   - timing, the Montgomery path against the general one
#   - constant time (ctgrind): with valgrind, an exponentiation with the
#     exponent's digits marked undefined; memcheck reports any branch or
#     address depending on them.  Only mpnorm, trimming the result (which
#     is public: it is sent, or the caller looks at it), may be reported.
#     The general path through the same check must be caught
#
# The constant-time check needs valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/mpexp_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/mpexp"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# the flags emu's libmp is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -w"
# what mpexp.c needs of libmp besides itself
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod betomp mprand mptoi; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done

fails=0

for limbs in 64 32; do
	def=""
	[ $limbs = 32 ] && def=-DMPEXP32
	if ! $CC $CFLAGS $def $INC -o "$TMP/mptest$limbs" "$D/mptest.c" $SRCS 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: mptest ($limbs-bit limbs) does not compile"
		exit 1
	fi
	if "$TMP/mptest$limbs" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		sed 's/^/    /' "$TMP/out"
		echo "PASS: $limbs-bit limbs: known answers, aliasing, random operands"
	else
		cat "$TMP/out"
		echo "FAIL: mptest, $limbs-bit limbs"
		fails=$((fails+1))
	fi
done

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
		for limbs in 64 32; do
			def=""
			[ $limbs = 32 ] && def=-DMPEXP32
			$cc $CFLAGS -DCTGRIND $def $INC -o "$TMP/mptest-ct" "$D/mptest.c" $SRCS || { echo "FAIL: mptest -DCTGRIND does not compile with $cc"; exit 1; }
			for what in ct ctslow; do
				for bits in 255 1024 2048; do
					[ $what = ctslow ] && [ $bits != 1024 ] && continue
					log="$TMP/vg.$what.$bits"
					valgrind --error-limit=no --read-inline-info=yes --log-file="$log" "$TMP/mptest-ct" $what $bits >/dev/null 2>&1
					# the function each report is in
					awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$log" | sort | uniq -c >"$TMP/fns"
					bad=$(awk '{print $2}' "$TMP/fns" | grep -v -x 'mpnorm')
					if [ $what = ctslow ]; then
						if [ -z "$bad" ]; then
							echo "FAIL: $cc: $limbs-bit limbs: the check did not catch the general path branching on the exponent"
							fails=$((fails+1))
						else
							echo "PASS: $cc: $limbs-bit limbs: the check catches the general path ($(echo $bad | tr '\n' ' '))"
						fi
					elif [ -n "$bad" ]; then
						echo "FAIL: $cc: $limbs-bit limbs: $bits bits: branches or addresses depend on the exponent in:"
						sed 's/^/    /' "$TMP/fns"
						fails=$((fails+1))
					else
						echo "PASS: $cc: $limbs-bit limbs: $bits-bit exponentiation constant time in the exponent"
					fi
				done
			done
		done
	done
fi

echo "----"
if [ "$fails" -eq 0 ]; then
	echo "mpexp: ALL PASS"
	exit 0
fi
echo "mpexp: $fails FAILED"
exit 1
