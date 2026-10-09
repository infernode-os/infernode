#!/bin/bash
#
# tests/host/mldsa_decompose_test.sh
#
# Guard ML-DSA's Decompose (libsec/mldsa_poly.c) on two counts.
#
# It must be right. Decompose feeds HighBits, LowBits, MakeHint and
# UseHint, so a wrong answer means signatures that fail to verify, or
# a signer's rejection check that passes what it must reject (INFR-108
# was that, at the wrap below q-1). Its domain is small -- the
# coefficients are reduced into (-q, q) first -- so this checks every
# input against FIPS 204 Algorithm 36, written out with % and / as the
# spec states it, for both gamma2 of the standard.
#
# It must not divide. Signing decomposes values derived from the
# secret key, and a hardware divide takes time that depends on its
# operands: CVE-2026-22705 is that leak in another implementation. A
# division by gamma2 cannot be turned into a multiply by the compiler,
# since gamma2 is a parameter, so a reintroduced `/` or `%` shows up as
# a divide instruction. This compiles the function at several
# optimisation levels and fails on any divide in the disassembly.
#
# The test extracts the real function text from the real source file,
# so it tracks what is in the tree rather than a copy that could drift.
#
# Run from project root: ./tests/host/mldsa_decompose_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="${SRCFILE:-$ROOT/libsec/mldsa_poly.c}"
VERBOSE=0

while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); return 0; }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); return 0; }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); return 0; }
info() { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; return 0; }
summary() {
    echo ""
    echo -e "${BOLD}Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED${NC}"
    [[ "$FAILED" -eq 0 ]] || exit 1
    exit 0
}

echo -e "${BOLD}ML-DSA Decompose: FIPS 204 Algorithm 36, without division${NC}"
echo ""

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }

CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || command -v gcc 2>/dev/null)"
if [[ -z "$CC" ]]; then
    skip "no C compiler available"
    summary
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Pull the real mldsa_decompose definition out of mldsa_poly.c.
python3 - "$SRCFILE" "$BUILD/decompose.c" <<'PYEOF'
import re, sys
src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()
m = re.search(r"\nvoid\nmldsa_decompose\s*\(([^)]*)\)\s*\n\{(.*?)\n\}", text, re.S)
if not m:
    sys.stderr.write("could not extract mldsa_decompose from %s\n" % src)
    sys.exit(2)
with open(out, "w") as f:
    f.write("typedef int int32;\n")
    f.write("enum { MLDSA_N = 256, MLDSA_Q = 8380417 };\n\n")
    f.write("void\nmldsa_decompose(%s)\n{%s\n}\n" % (m.group(1), m.group(2)))
PYEOF
if [[ $? -ne 0 ]]; then
    fail "could not extract mldsa_decompose from $SRCFILE"
    summary
fi

cat > "$BUILD/main.c" <<'EOF'
#include <stdio.h>

typedef int int32;
enum { Q = 8380417 };

void mldsa_decompose(int32 *a1, int32 *a0, int32 a, int32 gamma2);

/* FIPS 204 Algorithm 36, Decompose(r), as the spec writes it. */
static void
spec(int32 *r1, int32 *r0, int32 r, int32 gamma2)
{
	int32 rp, m;

	rp = ((r % Q) + Q) % Q;			/* r+ = r mod q */
	m = rp % (2 * gamma2);			/* r0 = r+ mod+- 2*gamma2 */
	if(m > gamma2)
		m -= 2 * gamma2;
	if(rp - m == Q - 1){
		*r1 = 0;
		*r0 = m - 1;
	} else {
		*r1 = (rp - m) / (2 * gamma2);
		*r0 = m;
	}
}

int
main(void)
{
	static const int32 gammas[] = { (Q - 1) / 88, (Q - 1) / 32 };
	int32 a, a1, a0, s1, s0, g;
	long bad;
	int i;

	bad = 0;
	for(i = 0; i < 2; i++){
		g = gammas[i];
		/* every coefficient mldsa_barrett_reduce can hand it: (-q, q) */
		for(a = -(Q - 1); a <= Q - 1; a++){
			mldsa_decompose(&a1, &a0, a, g);
			spec(&s1, &s0, a, g);
			if(a1 != s1 || a0 != s0){
				if(bad < 10)
					printf("  MISMATCH gamma2=%d a=%d got (%d,%d) want (%d,%d)\n",
						g, a, a1, a0, s1, s0);
				bad++;
			}
		}
		printf("  gamma2=%d: %d inputs checked\n", g, 2 * (Q - 1) + 1);
	}
	if(bad)
		printf("  %ld mismatches\n", bad);
	return bad != 0;
}
EOF

if ! "$CC" -O2 -o "$BUILD/t" "$BUILD/decompose.c" "$BUILD/main.c" 2>"$BUILD/cc.log"; then
    fail "extracted mldsa_decompose did not compile"
    [[ "$VERBOSE" -eq 1 ]] && cat "$BUILD/cc.log"
    summary
fi

OUT="$("$BUILD/t")"; rc=$?
info "$OUT"
if [[ $rc -eq 0 ]]; then
    pass "mldsa_decompose matches FIPS 204 Algorithm 36 on every input, both gamma2"
else
    fail "mldsa_decompose disagrees with FIPS 204 Algorithm 36"
    echo "$OUT" | grep -E 'MISMATCH|mismatches'
fi

# No divide instruction, at any optimisation level: x86 div/idiv,
# AArch64 and RISC-V sdiv/udiv/div/divu/divw/rem*.
OBJDUMP="$(command -v objdump 2>/dev/null || command -v llvm-objdump 2>/dev/null)"
if [[ -z "$OBJDUMP" ]]; then
    skip "no objdump: cannot inspect the compiled code for divides"
    summary
fi
DIVRE='^[[:space:]]*[0-9a-f]+:[[:space:]].*[[:space:]](i?div[bwlq]?|[su]div|divu?w?|remu?w?)([[:space:]]|$)'
for opt in -O0 -O1 -O2 -Os; do
    if ! "$CC" $opt -c -o "$BUILD/d$opt.o" "$BUILD/decompose.c" 2>"$BUILD/cc.log"; then
        fail "mldsa_decompose did not compile at $opt"
        continue
    fi
    DIVS="$("$OBJDUMP" -d "$BUILD/d$opt.o" | grep -Ei "$DIVRE")"
    if [[ -z "$DIVS" ]]; then
        pass "no divide instruction in mldsa_decompose at $opt"
    else
        fail "mldsa_decompose divides at $opt (variable-time on secret data)"
        echo "$DIVS" | sed 's/^/    /'
    fi
done

summary
