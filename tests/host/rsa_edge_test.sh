#!/bin/bash
#
# tests/host/rsa_edge_test.sh
#
# libsec's RSA (rsaencrypt.c, rsadecrypt.c, rsafill.c, rsagen.c) on the
# host under AddressSanitizer (tests/host/rsa_edge/rsatest.c), with a
# 2048-bit key, a representative and its signature from OpenSSL
# (tests/host/rsa_edge/vectors.txt, made by gen.py):
#
#   - a representative outside 0..n-1 has no result (RFC 8017 5.1.1,
#     5.1.2, 5.2.1, 5.2.2 step 1): s+n and s-n verified as s, m+n and
#     m-n were signed as m
#   - rsadecrypt checks its result before giving it out: with kp, kq or
#     c2 not the key's (a damaged key file, a fault) it returned a number
#     right mod one prime and wrong mod the other, from which
#     gcd(s^e - m, n) is a prime of the key
#   - rsafill with p == q is nil (mpinvert raised with two numbers made
#     and nothing to free them: 768 bytes of the kernel's pool a call
#     from RSAsk.fill), with a negative part nil (a raise, or a key every
#     use of which raised)
#   - rsagen's d is the least positive inverse of e (it was negative for
#     one key in ten, and rsafill refused such a key), 150 keys; its e
#     is odd and has the bits asked for (FIPS 186-5 A.1.1: above 2^16
#     for a caller that asks for 17)
#   - rsafill takes a d that inverts e mod lcm(p-1, q-1), which is what
#     RFC 8017 3.2 and FIPS 186-5 define and OpenSSL writes (it wanted
#     (p-1)(q-1), and refused such keys), and refuses e = d = 1 and
#     any e that is 1 mod it (a key that changes nothing)
#   - libmp's mpexpcrt, the private operation in constant time, gives
#     what the general arithmetic gives for keys of 64 to 1024 bits and
#     inputs at the edges and at random, and for primes of unlike
#     lengths; what it is not for is refused
#   - rsadecrypt blinds: it draws a number from the generator at every
#     call (it drew none), and gives OpenSSL's answer each time
#   - constant time (ctgrind): with valgrind, the key's p, q, kp, kq and
#     c2 marked undefined.  mpexpcrt, with the input undefined too, is
#     reported nowhere but in mpnorm trimming its result; the
#     arithmetic rsadecrypt had before must be caught by the same
#     check (it divides by the primes); and in the whole of rsadecrypt
#     nothing is reported inside mpexpcrt or before it, and after it
#     only the comparison that checks the result (of two numbers that
#     are equal) and mpnorm
#
# The constant-time checks need valgrind (Linux); CI installs it, and
# there its absence is a failure.  No emulator is needed.
#
# Run from project root: ./tests/host/rsa_edge_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/rsa_edge"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo 'int main(void){return 0;}' > "$TMP/san.c"
if ! $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null || ! "$TMP/san"; then
	echo "SKIP: $CC has no AddressSanitizer here"
	exit 77
fi

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
CFLAGS="-g -O -fno-strict-aliasing -w -fsanitize=address,undefined -fno-sanitize-recover=undefined"
# (RSA_SRC: a directory with another libsec's sources, to see what they do)
LIBSEC="${RSA_SRC:-$ROOT/libsec}"
SRCS=""
for f in mpaux mpadd mpsub mpcmp mpmul mpleft mpright mpvecadd mpvecsub \
	mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpmod mpexp mpextendedgcd mpinvert \
	betomp letomp mptobe mprand mptoi mptoui mpfmt strtomp; do
	SRCS="$SRCS $ROOT/libmp/$f.c"
done
for f in rsaencrypt rsadecrypt rsafill rsaalloc rsagen probably_prime smallprimetest genprime; do
	SRCS="$SRCS $LIBSEC/$f.c"
done
PLAIN="-g -O -fno-strict-aliasing -w"

objs=""
for s in $SRCS; do
	o="$TMP/$(basename "$s" .c).o"
	if ! $CC $CFLAGS -Dmalloc=xmalloc -Dfree=xfree $INC -c -o "$o" "$s" 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: $s does not compile"
		exit 1
	fi
	objs="$objs $o"
done
if ! $CC $CFLAGS $INC -o "$TMP/rsatest" "$D/rsatest.c" $objs "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: rsatest does not compile"
	exit 1
fi

fails=0
if ASAN_OPTIONS=detect_leaks=0 with_timeout 120 "$TMP/rsatest" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: RSA's ranges, its checked result, rsafill's refusals, rsagen's d, mpexpcrt and blinding"
else
	grep -v "p == q = 11" "$TMP/out" | head -40
	echo "FAIL: rsatest"
	fails=1
fi

# ctgrind
if ! command -v valgrind >/dev/null 2>&1 || [ ! -f /usr/include/valgrind/memcheck.h ]; then
	if [ -n "${CI:-}" ] && [ "$(uname)" = Linux ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the constant-time check did not run"
		exit 1
	fi
	echo "SKIP: constant-time check (needs valgrind and its headers)"
	exit $fails
fi
ccs="$CC"
command -v clang >/dev/null 2>&1 && [ "$CC" != clang ] && ccs="$ccs clang"
for cc in $ccs; do
	if ! $cc $PLAIN -DCTGRIND $INC -o "$TMP/rsatest-ct" "$D/rsatest.c" $SRCS "$ROOT/lib9/u32.c" "$ROOT/lib9/u64.c" 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: rsatest -DCTGRIND does not compile with $cc"
		exit 1
	fi
	for what in crt general rsa; do
		log="$TMP/vg.$what"
		valgrind --error-limit=no --read-inline-info=yes --num-callers=30 --log-file="$log" "$TMP/rsatest-ct" ct $what "$D/vectors.txt" >"$TMP/ct.out" 2>&1
		st=$?
		if [ $st -ne 0 ]; then
			cat "$TMP/ct.out"
			echo "FAIL: $cc: rsatest ct $what did not give the answer"
			fails=$((fails+1))
			continue
		fi
		# the function each report is in
		awk '/depends on uninitialised|Use of uninitialised/ { getline; sub(/.*: /, ""); sub(/ \(.*/, ""); print }' "$log" | sort | uniq -c >"$TMP/fns"
		case $what in
		crt)
			bad=$(awk '{print $2}' "$TMP/fns" | grep -v -x 'mpnorm')
			if [ -n "$bad" ]; then
				echo "FAIL: $cc: mpexpcrt: branches or addresses depend on the key or the input in:"
				sed 's/^/    /' "$TMP/fns"
				fails=$((fails+1))
			else
				echo "PASS: $cc: mpexpcrt is constant time in p, q, kp, kq, c2 and its input (only mpnorm, trimming the result)"
			fi
			;;
		general)
			if ! grep -q 'mpdiv\|mpdigdiv' "$TMP/fns"; then
				echo "FAIL: $cc: the check did not catch the arithmetic rsadecrypt had dividing by the primes"
				fails=$((fails+1))
			else
				echo "PASS: $cc: the check catches the arithmetic rsadecrypt had ($(awk '{print $2}' "$TMP/fns" | tr '\n' ' '))"
			fi
			;;
		rsa)
			# where rsadecrypt calls mpexpcrt: but for mpnorm trimming
			# its result, nothing may be reported in it or before it
			line=$(grep -n 'mpexpcrt(x, rsa->p' "$LIBSEC/rsadecrypt.c" | head -1 | cut -d: -f1)
			early=$(awk -v l="${line:-0}" '
				/depends on uninitialised|Use of uninitialised/ { if(inrep) flush(); inrep = 1; at = ""; in_crt = 0; ln = 0; next }
				inrep && /    at 0x/ { at = $0; sub(/.*: /, "", at); sub(/ \(.*/, "", at) }
				inrep && /mpexpcrt|montmul|montexp|montrr|crtgeneral/ { in_crt = 1 }
				inrep && /rsadecrypt \(rsadecrypt.c:[0-9]+\)/ { s = $0; sub(/.*rsadecrypt.c:/, "", s); sub(/\).*/, "", s); ln = s+0 }
				inrep && !/    (at|by) 0x/ { flush() }
				function flush() { if(at != "mpnorm" && (in_crt || ln <= l)) print at ":" ln; inrep = 0 }
				END { if(inrep) flush() }' "$log" | sort -u | tr '\n' ' ')
			late=$(awk '{print $2}' "$TMP/fns" | grep -v -x 'mpnorm\|mpveccmp\|mpmagcmp\|mpcmp\|rsadecrypt' | tr '\n' ' ')
			if [ -z "$line" ] || [ -n "$early$late" ]; then
				echo "FAIL: $cc: rsadecrypt: the key reaches a branch or an address in or before the private operation ($early) or after it ($late):"
				sed 's/^/    /' "$TMP/fns"
				fails=$((fails+1))
			else
				echo "PASS: $cc: rsadecrypt: nothing depends on the key in or before the private operation; after it only the check of the result ($(awk '{print $2}' "$TMP/fns" | tr '\n' ' '))"
			fi
			;;
		esac
	done
done
[ $fails -eq 0 ] && exit 0
exit 1
