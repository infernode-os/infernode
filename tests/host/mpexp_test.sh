#!/bin/bash
#
# tests/host/mpexp_test.sh
#
# libmp's mpexp (IPint.expmod, RSA, Diffie-Hellman, ElGamal, DSA), built
# on the host with tests/host/mpexp/mpexptest.c:
#
#   - Montgomery's path (an odd modulus) against the square and multiply
#     it replaced, on random and patterned inputs: every size from one
#     digit to 4096 bits, bases 0, 1, m-1, larger than m and negative,
#     the result in place of the base, exponent or modulus
#   - known answers from Python's pow (tests/host/mpexp/gen.py, made at
#     each run with a fixed seed), an even modulus and modulus 1 among
#     them
#   - constant time (ctgrind): with valgrind, a 2048-bit exponentiation
#     with the exponent (but its top digit, which fixes its length)
#     marked undefined; memcheck reports any branch or address depending
#     on it.  None may be reported but in mpnorm, which trims the
#     result's leading zero digits as it is handed back.  The square and
#     multiply it replaced must be reported, or the check sees nothing
#   - the times of both, printed
#
# CC=clang checks clang's code.  The constant-time check needs valgrind
# (Linux); CI installs it, and there its absence is a failure.  No
# emulator is needed.
#
# Run from project root: ./tests/host/mpexp_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/mpexp"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }
LIB9="$ROOT/$EMUHOST/$OBJTYPE/lib/lib9.a"
[ -f "$LIB9" ] || { echo "SKIP: $LIB9 not built"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# the flags emu's libmp is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -w"
# libmp's files as its mkfile lists them, less mpexp (the test includes
# it) and mprand (it needs genrandom)
SRC=$(sed -n '/^FILES=/,/^$/p' "$ROOT/libmp/mkfile" | sed 's/[\\	 ]//g' | grep -v '^FILES=\|^$\|^mpexp$\|^mprand$' | sed "s|.*|$ROOT/libmp/&.c|")

fails=0

if ! $CC $CFLAGS $INC -o "$TMP/mpexptest" "$D/mpexptest.c" $SRC "$LIB9" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: mpexptest does not compile"
	exit 1
fi

if "$TMP/mpexptest" diff 1500 >"$TMP/out" 2>&1; then
	cat "$TMP/out"
	echo "PASS: Montgomery's path agrees with square and multiply"
else
	cat "$TMP/out"
	echo "FAIL: Montgomery's path differs"
	fails=$((fails+1))
fi

if command -v python3 >/dev/null 2>&1; then
	python3 "$D/gen.py" >"$TMP/vec.txt"
	if "$TMP/mpexptest" vec "$TMP/vec.txt" >"$TMP/out" 2>&1; then
		cat "$TMP/out"
		echo "PASS: known answers from Python's pow"
	else
		cat "$TMP/out"
		echo "FAIL: known answers"
		fails=$((fails+1))
	fi
else
	echo "SKIP: known answers (no python3)"
fi

"$TMP/mpexptest" time

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
else
	ccs="$CC"
	command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
	for cc in $ccs; do
		$cc $CFLAGS -DCTGRIND $INC -o "$TMP/mpexptest-ct" "$D/mpexptest.c" $SRC "$LIB9" || { echo "FAIL: mpexptest -DCTGRIND does not compile with $cc"; exit 1; }
		for what in mont plain; do
			arg=; [ $what = plain ] && arg=plain
			valgrind --error-limit=no --read-inline-info=yes --log-file="$TMP/vg.$what" "$TMP/mpexptest-ct" ct $arg >/dev/null 2>&1
			# the function each report is in
			awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$TMP/vg.$what" | sort | uniq -c >"$TMP/fns.$what"
			bad=$(awk '{print $2}' "$TMP/fns.$what" | grep -v -x 'mpnorm')
			if [ $what = plain ]; then
				if [ -n "$bad" ]; then
					echo "PASS: $cc: the square and multiply it replaced is reported ($(echo $bad | tr '\n' ' '))"
				else
					echo "FAIL: $cc: the check saw nothing in the square and multiply: it would miss a leak"
					fails=$((fails+1))
				fi
			elif [ -n "$bad" ]; then
				echo "FAIL: $cc: branches or addresses depend on the exponent in:"
				sed 's/^/    /' "$TMP/fns.$what"
				fails=$((fails+1))
			else
				echo "PASS: $cc: Montgomery's exponentiation constant time in the exponent"
			fi
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
