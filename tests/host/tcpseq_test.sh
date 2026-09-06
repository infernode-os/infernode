#!/bin/bash
#
# tests/host/tcpseq_test.sh
#
# Guard os/ip/tcp.c's sequence-number arithmetic against LP64.
#
# WHY THIS TEST EXISTS BEFORE THE PORT DOES
#
# tcp.c is the second file in os/ip with a silent-wrong-answer failure
# mode, and its bug is nastier than iproute.c's because it is a bug of
# SURVIVAL BY ACCIDENT rather than of obvious breakage.
#
# TCP sequence numbers are 32 bits and MUST wrap. The comparisons are
# written the classic way:
#
#     int seq_lt(ulong x, ulong y) { return (int)(x-y) < 0; }
#
# and under LP64 those keep working -- x-y is computed in 64 bits, and
# the (int) cast truncates it back to the 32-bit difference the
# algorithm wanted. So every comparison passes a smoke test.
#
# What does NOT survive is everything around them:
#
#   1. The sequence FIELDS are ulong, so on LP64 they are 64 bits wide
#      and sequence arithmetic no longer wraps. nxt = 0xFFFFFF00 plus
#      0x200 must be 0x00000100; in a 64-bit word it is 0x100000100,
#      and the connection's idea of where it is in the stream silently
#      leaves the 32-bit space that the protocol is defined in.
#
#   2. seq_within() compares its arguments DIRECTLY with <= -- no (int)
#      truncation to rescue it. Fed a value that has escaped 32 bits it
#      takes the wrong branch of its wrapped-range test and answers
#      confidently backwards.
#
#   3. tcp.c:2143 computes snd.una-(1<<31). 1<<31 overflows a signed
#      int, which is undefined behaviour; in practice it is INT_MIN,
#      which then sign-extends when converted to a 64-bit ulong.
#
# None of this crashes. A connection that mis-compares sequence numbers
# stalls, retransmits, or silently drops data -- it looks like a bad
# network, and it looks like a bad network for about a week.
#
# The test extracts the real functions and the real declared types from
# the real source, so it measures the tree rather than a remembered
# version of it -- the same approach nhgetl_test.sh and iproute_test.sh
# take.
#
# Run from project root: ./tests/host/tcpseq_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="$ROOT/os/ip/tcp.c"
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
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); }
info() { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; }

echo -e "${BOLD}TCP sequence arithmetic under LP64${NC}"
echo ""

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }
CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)"
[[ -n "$CC" ]] || { skip "no C compiler"; echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 0; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# The real comparison functions, lifted out of the real file.
{ echo "int"; awk '/^seq_within\(/,/^}/' "$SRCFILE"; } > "$BUILD/seq.inc"
for f in seq_lt seq_le seq_gt seq_ge; do
    { echo "int"; awk -v fn="^$f\\\\(" '$0 ~ fn,/^}/' "$SRCFILE"; } >> "$BUILD/seq.inc"
done
if ! grep -q seq_lt "$BUILD/seq.inc"; then
    fail "could not extract the sequence comparisons from $SRCFILE"
    echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 1
fi
info "extracted $(wc -l < "$BUILD/seq.inc" | tr -d ' ') lines of comparison code"

# The declared type of a sequence FIELD. snd.una is representative:
# every sequence-bearing field in Tcpctl is declared the same way.
SEQTYPE="$(grep -oE '^[[:space:]]*(u32int|ulong|uint)[[:space:]]+una;' "$SRCFILE" | head -1 | awk '{print $1}')"
SEQTYPE="${SEQTYPE:-ulong}"
info "sequence field type: $SEQTYPE"

# How the source spells the half-space constant.
HALF="$(grep -oE 'snd\.una-\(1U?<<31\)' "$SRCFILE" | head -1)"
info "half-space expression: ${HALF:-<absent>}"

# Spelled exactly as the source spells it, and computed BEFORE the
# heredoc below expands it.
if [[ -n "$HALF" ]]; then
    HALF_EXPR="$(sed 's/^snd\.una-//' <<<"$HALF")"
else
    HALF_EXPR="(1<<31)"
fi

cat > "$BUILD/t.c" <<EOF
#include <stdio.h>

typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned int u32int;
typedef unsigned int uint;

/*
 * No forward declaration: seq_within is extracted first, so it is
 * defined before anything uses it. Declaring it here would pin the
 * argument types, which are exactly what this test is measuring.
 */
$(cat "$BUILD/seq.inc")

static int bad;

static void
check(const char *what, int got, int want)
{
	printf("%-52s got=%d want=%d %s\n", what, got, want,
		got == want ? "ok" : "BAD");
	if(got != want)
		bad = 1;
}

int
main(void)
{
	/*
	 * 1. Sequence arithmetic must WRAP at 32 bits. This is the
	 *    property the protocol is defined in terms of, and the one a
	 *    64-bit field silently removes.
	 */
	{
		$SEQTYPE nxt;

		nxt = 0xFFFFFF00;
		nxt += 0x200;
		printf("%-52s nxt=%#lx\n", "wrap: 0xFFFFFF00 + 0x200", (ulong)nxt);
		check("  wraps to 0x100 (32-bit sequence space)",
			(ulong)nxt == 0x100UL, 1);
	}

	/*
	 * 2. The comparisons themselves, including across a wrap. These
	 *    pass either way -- recorded so a future reader can see that
	 *    they are NOT the evidence, and does not conclude the file is
	 *    fine because they are green.
	 */
	check("seq_lt(0xFFFFFFF0, 0x00000010) across the wrap",
		seq_lt(0xFFFFFFF0UL, 0x00000010UL), 1);
	check("seq_gt(0x00000010, 0xFFFFFFF0) across the wrap",
		seq_gt(0x00000010UL, 0xFFFFFFF0UL), 1);
	check("seq_le(x, x)", seq_le(12345UL, 12345UL), 1);
	check("seq_ge(x, x)", seq_ge(12345UL, 12345UL), 1);

	/*
	 * 3. seq_within with a value that has left the 32-bit space.
	 *    There is no (int) cast in seq_within to rescue it: it
	 *    compares its arguments directly.
	 */
	{
		$SEQTYPE nxt;

		nxt = 0xFFFFFF00;
		nxt += 0x200;			/* 0x100 if it wraps */

		/*
		 * A NON-wrapped range, deliberately. 0x100 is inside
		 * [0x50, 0x200]; a field that failed to wrap holds
		 * 0x100000100, which is not -- and seq_within takes the
		 * low<=high branch and answers 0.
		 *
		 * A wrapped range would NOT discriminate here: seq_within's
		 * other branch is "x >= low || x <= high", and 0x100000100
		 * satisfies the first half, so it answers 1 for the wrong
		 * reason. Worth stating because that was the first witness
		 * tried, and it passed against known-broken code.
		 */
		check("seq_within(nxt, 0x50, 0x200) after a wrap",
			seq_within((ulong)nxt, 0x50UL, 0x00000200UL), 1);
	}

	/*
	 * 4. The half-space constant at tcp.c:2143. 1<<31 overflows a
	 *    signed int; the value wanted is 0x80000000.
	 */
	{
		/*
		 * una is declared with the SOURCE's type, not ulong: the
		 * whole question is what width this subtraction happens in.
		 * Hardcoding ulong here would test the test, not the tree.
		 */
		$SEQTYPE una = 0x1000;
		ulong lo;

		lo = (ulong)(una - $HALF_EXPR);
		printf("%-52s lo=%#lx\n", "una - half-space", lo);
		check("  half-space subtraction stays in 32 bits",
			(lo >> 32) == 0, 1);
	}

	return bad;
}
EOF

if "$CC" -O2 -o "$BUILD/t" "$BUILD/t.c" 2>"$BUILD/cc.log"; then
    OUT="$("$BUILD/t" 2>&1)"; RC=$?
    if [[ "$VERBOSE" -eq 1 ]]; then echo "$OUT" | sed 's/^/  /'; fi
    if [[ $RC -eq 0 ]]; then
        pass "sequence arithmetic wraps and compares correctly under LP64"
    else
        fail "TCP sequence arithmetic is wrong under LP64"
        echo "$OUT" | grep -E 'BAD|nxt=|lo=' | sed 's/^/    /'
    fi
else
    fail "test did not compile"
    sed 's/^/    /' "$BUILD/cc.log" | head -12
fi

# A source-level check: whatever the fix is, the fields must be 32 bits.
if [[ "$SEQTYPE" == "u32int" || "$SEQTYPE" == "uint" ]]; then
    pass "sequence fields are 32 bits wide ($SEQTYPE)"
else
    fail "sequence fields are declared $SEQTYPE; on LP64 that is 64 bits and does not wrap"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
[[ $FAILED -eq 0 ]]
