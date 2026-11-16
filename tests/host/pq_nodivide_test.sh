#!/bin/bash
#
# tests/host/pq_nodivide_test.sh
#
# The places where libsec's ML-KEM and ML-DSA reduce or round a secret
# value by a constant must be right, and must not divide.
#
# A divide instruction takes time that depends on its operands, and
# these operands are secret: ML-KEM's Compress_d rounds 2^d/q times a
# coefficient of v - s^T u (the message, in decryption) and of the
# re-encryption (the KyberSlash attacks on other implementations were
# this); ML-DSA's key generation reduces a nibble of the secret seed's
# expansion mod 5.  Written with / and %, each was compiled without a
# divide at the flags the tree ships with and with one at others (gcc
# -Os, clang -O0): right by the compiler's leave.  They are now
# multiplications by construction, as Decompose is
# (mldsa_decompose_test.sh), and this test holds them to it:
#
#   - each function is taken from the real source file, compiled, and
#     checked on every input against the standard's definition written
#     with / and %: Compress_d (FIPS 203 section 4.2.1) for every
#     coefficient in (-q, q) and every d from 1 to 11
#   - compiled at -O0, -O1, -O2 and -Os by each compiler here (cc, and
#     clang where there is one, for this machine and for the native
#     kernels' aarch64 and riscv64 and a 32-bit ARM where clang has the
#     target), the object code has no divide instruction and no call to
#     a divide helper
#
# Run from project root: ./tests/host/pq_nodivide_test.sh
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }
skip() { echo "SKIP: $1"; SKIPPED=$((SKIPPED+1)); }
summary() {
	echo "----"
	echo "pq_nodivide: $PASSED passed, $FAILED failed, $SKIPPED skipped"
	[ "$FAILED" -eq 0 ] || exit 1
	exit 0
}

CC="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null)"
[ -n "$CC" ] || { echo "SKIP: no C compiler"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3 (it takes the functions out of the sources)"; exit 77; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Take a function's definition out of a source file: its return type
# line, its name line and its body, as the tree writes functions.
extract() {	# file type name out prelude
	python3 - "$1" "$2" "$3" "$4" "$5" <<'PYEOF'
import re, sys
src, typ, name, out, prelude = sys.argv[1:6]
text = open(src, encoding="utf-8", errors="replace").read()
m = re.search(r"\n(?:static )?%s\n%s\s*\(([^)]*)\)\s*\n\{(.*?)\n\}" % (re.escape(typ), re.escape(name)), text, re.S)
if not m:
	sys.stderr.write("could not take %s out of %s\n" % (name, src))
	sys.exit(2)
with open(out, "w") as f:
	f.write(prelude + "\n")
	f.write("%s\n%s(%s)\n{%s\n}\n" % (typ, name, m.group(1), m.group(2)))
PYEOF
}

PRE='typedef short int16; typedef int int32; typedef unsigned short u16int; typedef unsigned int u32int; typedef unsigned long long u64int; typedef unsigned char uchar;'

if ! extract "$ROOT/libsec/mlkem_poly.c" u16int compress "$BUILD/compress.c" "$PRE enum { MLKEM_N = 256, MLKEM_Q = 3329 };"; then
	fail "could not take compress out of libsec/mlkem_poly.c"
	summary
fi

cat >"$BUILD/compress_main.c" <<'EOF2'
#include <stdio.h>
unsigned short compress(short x, int d);
enum { Q = 3329 };
int
main(void)
{
	int x, d, xx;
	long long want;
	long bad, n;

	bad = n = 0;
	for(d = 1; d <= 11; d++)
		for(x = -(Q-1); x <= Q-1; x++){
			/* Compress_d(x) = round(2^d/q * x) mod 2^d, halves up (FIPS 203 4.2.1) */
			xx = x < 0 ? x + Q : x;
			want = ((2LL*xx << d) + Q) / (2*Q) % (1 << d);
			n++;
			if(compress(x, d) != want){
				if(bad++ < 10)
					printf("  MISMATCH d=%d x=%d got %d want %lld\n", d, x, compress(x, d), want);
			}
		}
	printf("  %ld inputs checked\n", n);
	return bad != 0;
}
EOF2

if ! "$CC" -O2 -o "$BUILD/compress_t" "$BUILD/compress.c" "$BUILD/compress_main.c" 2>"$BUILD/cc.log"; then
	cat "$BUILD/cc.log"
	fail "ML-KEM compress did not compile"
elif "$BUILD/compress_t" >"$BUILD/out" 2>&1; then
	pass "ML-KEM compress is FIPS 203's Compress_d for every coefficient in (-q, q) and d from 1 to 11 ($(sed 's/^ *//' "$BUILD/out"))"
else
	sed 's/^/  /' "$BUILD/out" | head -12
	fail "ML-KEM compress disagrees with FIPS 203's Compress_d"
fi

# No divide: x86 div/idiv, AArch64 sdiv/udiv, RISC-V div/divu/divw/rem*,
# 32-bit ARM's helpers (__aeabi_uidiv, __udivdi3 and the like, seen as
# relocations).
OBJDUMP="$(command -v llvm-objdump 2>/dev/null || command -v objdump 2>/dev/null)"
if [ -z "$OBJDUMP" ]; then
	skip "no objdump: cannot look for divides in the compiled code"
	summary
fi
DIVRE='(^[[:space:]]*[0-9a-f]+:[[:space:]].*[[:space:]](i?div[bwlq]?|[su]div|divu?w?|remu?w?)([[:space:]]|$))|(__(aeabi_)?[a-z]*div[a-z0-9]*)|(__u?mod[sd]i3)'

nodivide() {	# what file.c
	local what=$1 src=$2 cc target opt o divs bad="" n=0
	local ccs="$CC"
	command -v clang >/dev/null 2>&1 && [ "$(basename "$CC")" != clang ] && ccs="$ccs clang"
	for cc in $ccs; do
		local targets="host"
		if "$cc" --version 2>/dev/null | grep -qi clang; then
			for t in aarch64-elf riscv64-unknown-elf armv7a-none-eabi; do
				"$cc" --print-targets 2>/dev/null | grep -q "^ *${t%%-*}\b\|^ *arm " && targets="$targets $t"
			done
		fi
		for target in $targets; do
			local tf=""
			[ "$target" != host ] && tf="--target=$target -ffreestanding"
			# can this compiler make an object for the target at all?
			echo 'int f(int a){return a+1;}' >"$BUILD/probe.c"
			"$cc" $tf -c -o "$BUILD/probe.o" "$BUILD/probe.c" >/dev/null 2>&1 || continue
			# the 32-bit ARM's objects want an objdump that knows them
			[ "$target" != host ] && ! "$OBJDUMP" -dr "$BUILD/probe.o" >/dev/null 2>&1 && continue
			for opt in -O0 -O1 -O2 -Os; do
				o="$BUILD/nd.o"
				if ! "$cc" $tf $opt -c -o "$o" "$src" 2>"$BUILD/cc.log"; then
					bad="$bad\n    $(basename "$cc") $target $opt: does not compile"
					continue
				fi
				n=$((n+1))
				divs="$("$OBJDUMP" -dr "$o" | grep -Ei "$DIVRE" | head -3)"
				[ -n "$divs" ] && bad="$bad\n    $(basename "$cc") $target $opt: $(echo "$divs" | tr -s ' \t' ' ' | head -1)"
			done
		done
	done
	if [ -n "$bad" ]; then
		fail "$what divides (variable time on secret data):$(printf '%b' "$bad")"
	else
		pass "no divide in $what, $n compilations (compilers, targets, -O0 -O1 -O2 -Os)"
	fi
}

nodivide "ML-KEM compress" "$BUILD/compress.c"

summary
