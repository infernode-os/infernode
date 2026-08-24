#!/bin/bash
#
# tests/host/iproute_test.sh
#
# Guard os/ip/iproute.c's route-range arithmetic against LP64.
#
# WHY THIS TEST EXISTS BEFORE THE PORT DOES
#
# iproute.c is the one file in os/ip with a silent-wrong-answer failure
# mode. A route table that returns the wrong route does not crash and
# does not log; it misroutes, and the symptom appears somewhere else
# entirely, days later, as "the network is flaky". Every other hazard in
# os/ip announces itself by comparison.
#
# It also holds three separate width bugs, all of which are invisible on
# the 32-bit machines upstream was written for and all of which change
# behaviour under LP64, where ulong is 64 bits:
#
#   1. v4addroute computes  ea = sa | ~m  with ulong sa, m, ea.
#      m comes from nhgetl(), so it holds a 32-bit value in a 64-bit
#      word and its top 32 bits are ZERO. ~m therefore sets all of them,
#      and the route's end address becomes 0xFFFFFFFF_xxxxxxxx instead
#      of a 32-bit broadcast address. Lookup compares
#      "addr <= endaddress", so the route then matches addresses far
#      outside its subnet -- it captures traffic belonging to other
#      routes, silently.
#
#   2. v6addroute builds  ulong sa[IPllen]  -- four 32-bit values, one
#      per word -- and then copies it out with
#      memmove(p->v6.address, sa, IPaddrlen). IPaddrlen is 16, which was
#      exactly four words on a 32-bit machine and is only TWO here. So
#      half the address is dropped, and the half that survives is
#      interleaved with the zero padding of the 64-bit words. Every IPv6
#      route is wrong.
#
#   3. The V4H/V6H hash macros shift by (32-Lroot-5), which assumes the
#      value being hashed is 32 bits wide. Fed a 64-bit ea from bug 1,
#      the mask saves them -- but only by accident, and the accident is
#      worth pinning down rather than relying on.
#
# The test extracts the real expressions from the real source file, so
# it tracks what is in the tree rather than a copy that can drift. That
# is the same approach tests/host/nhgetl_test.sh takes, and this is the
# test that file's header comment predicted would be needed:
#
#     "upstream Inferno's os/ip computes route ranges as (start | ~mask)
#      ... with sign-extended inputs both silently produce WRONG ANSWERS
#      rather than failing."
#
# Run from project root: ./tests/host/iproute_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="$ROOT/os/ip/iproute.c"
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

echo -e "${BOLD}os/ip route-range arithmetic under LP64${NC}"
echo ""

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }

CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)"
[[ -n "$CC" ]] || { skip "no C compiler"; echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 0; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

#
# Pull the real expressions out of the real file.
#
# Matching on the source rather than restating it is the point: if
# someone "fixes" one of these by editing iproute.c, this test compiles
# the edited version and says whether the edit was right.
#
V4EA="$(grep -oE '^[[:space:]]*ea = sa \| ~m;' "$SRCFILE" | head -1 | sed 's/^[[:space:]]*//')"
V6COPY="$(grep -oE 'memmove\(p->v6\.address, sa, [A-Za-z]+\);' "$SRCFILE" | head -1)"
V4HASH="$(grep -oE '^#define[[:space:]]+V4H\(a\).*$' "$SRCFILE" | head -1)"

# The DECLARED TYPES matter as much as the expressions -- the whole bug
# is that these hold 32-bit values in whatever width ulong happens to
# be. Pull them from the source so the test measures the tree, not a
# remembered version of it.
V4TYPE="$(sed -n '/^v4addroute/,/^}/p' "$SRCFILE" | grep -oE '\b(u32int|ulong|uint)\b(?=[[:space:]]+sa;)' 2>/dev/null | head -1)"
[[ -n "$V4TYPE" ]] || V4TYPE="$(sed -n '/^v4addroute/,/^}/p' "$SRCFILE" | grep -oE '^[[:space:]]*(u32int|ulong|uint)[[:space:]]+sa;' | head -1 | awk '{print $1}')"
V6TYPE="$(sed -n '/^v6addroute/,/^}/p' "$SRCFILE" | grep -oE '^[[:space:]]*(u32int|ulong|uint)[[:space:]]+sa\[IPllen\]' | head -1 | awk '{print $1}')"
V4TYPE="${V4TYPE:-ulong}"
V6TYPE="${V6TYPE:-ulong}"

if [[ -z "$V4EA" ]]; then
    info "no 'ea = sa | ~m;' in $SRCFILE -- it may already be fixed"
fi
info "v4 end-address expr: ${V4EA:-<absent>}"
info "v6 address copy:     ${V6COPY:-<absent>}"
info "v4 hash:             ${V4HASH:-<absent>}"
info "v4 address type:     $V4TYPE"
info "v6 address type:     $V6TYPE"

#
# 1. The v4 end-address computation.
#
# Reproduces the declarations and the extracted expression verbatim, so
# the arithmetic under test is the arithmetic in the tree.
#
cat > "$BUILD/v4.c" <<EOF
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned int u32int;	/* as Inferno/arm64/include/u.h defines it */

/* as os/port/ipaux.c defines it, with the LP64 casts */
static ulong
nhgetl(void *p)
{
	uchar *a = p;
	return ((ulong)a[0]<<24) | ((ulong)a[1]<<16) | ((ulong)a[2]<<8) | (ulong)a[3];
}

int
main(void)
{
	uchar a[4]    = {192, 168, 1, 0};
	uchar mask[4] = {255, 255, 255, 0};
	$V4TYPE sa, m, ea;
	int bad = 0;

	m = nhgetl(mask);
	sa = nhgetl(a) & m;
	${V4EA:-ea = sa | ~m;}

	printf("sa=%016lx ea=%016lx\n", (ulong)sa, (ulong)ea);

	/*
	 * 192.168.1.0/24 ends at 192.168.1.255 == 0xC0A801FF. Anything
	 * above 32 bits means the route claims addresses it does not own.
	 */
	if((ulong)ea != 0xC0A801FFUL){
		printf("BAD end address: got %016lx want 00000000c0a801ff\n", (ulong)ea);
		bad = 1;
	}
	if((ulong)ea >> 32){
		printf("BAD: end address has bits above 32 set (%016lx)\n", (ulong)ea);
		bad = 1;
	}

	/*
	 * The consequence, stated as the lookup does it: an address in a
	 * DIFFERENT network must not fall inside this route's range.
	 */
	{
		/*
		 * 192.168.2.1 is in the NEXT subnet and must not match. It
		 * sorts ABOVE the range, which is the direction the broken
		 * end address opens up -- an address below the start is
		 * still excluded by the "o >= sa" half, so a witness below
		 * the range would pass even with the bug present.
		 */
		uchar other[4] = {192, 168, 2, 1};
		ulong o = nhgetl(other);
		if(o >= (ulong)sa && o <= (ulong)ea){
			printf("BAD: 192.168.2.1 matches the 192.168.1.0/24 route"
				" -- this route captures traffic it does not own\n");
			bad = 1;
		}
	}
	return bad;
}
EOF

if "$CC" -O2 -o "$BUILD/v4" "$BUILD/v4.c" 2>"$BUILD/v4.log"; then
    OUT="$("$BUILD/v4" 2>&1)"; RC=$?
    info "$OUT"
    if [[ $RC -eq 0 ]]; then
        pass "v4 route end address stays within 32 bits (no stray match)"
    else
        fail "v4 route end address is wrong under LP64"
        [[ "$VERBOSE" -eq 0 ]] && echo "$OUT" | sed 's/^/    /'
    fi
else
    fail "v4 test did not compile"
    cat "$BUILD/v4.log" | sed 's/^/    /'
fi

#
# 2. The v6 address copy.
#
# The bug is a size mismatch between the ulong[] the address is built in
# and the byte count used to copy it out, so the test asserts on that
# relationship directly rather than on a magic number.
#
cat > "$BUILD/v6.c" <<EOF
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned int u32int;	/* as Inferno/arm64/include/u.h defines it */

enum { IPaddrlen = 16, IPllen = 4 };

static ulong
nhgetl(void *p)
{
	uchar *a = p;
	return ((ulong)a[0]<<24) | ((ulong)a[1]<<16) | ((ulong)a[2]<<8) | (ulong)a[3];
}

int
main(void)
{
	/* 2001:db8::/32 */
	uchar a[IPaddrlen]    = {0x20,0x01,0x0d,0xb8,0,0,0,0,0,0,0,0,0,0,0,0};
	uchar mask[IPaddrlen] = {0xff,0xff,0xff,0xff,0,0,0,0,0,0,0,0,0,0,0,0};
	$V6TYPE sa[IPllen], ea[IPllen];
	$V6TYPE x, y;
	int h, bad = 0;

	for(h = 0; h < IPllen; h++){
		x = nhgetl(a+4*h);
		y = nhgetl(mask+4*h);
		sa[h] = x & y;
		ea[h] = x | ~y;
	}

	printf("sizeof(sa)=%zu IPaddrlen=%d\n", sizeof sa, IPaddrlen);

	/*
	 * v6addroute copies the built address out with
	 * memmove(dst, sa, IPaddrlen). That is only correct when the
	 * array is exactly IPaddrlen bytes -- true when ulong is 32 bits,
	 * false here. Copying 16 bytes out of a 32-byte array takes two
	 * words and loses the other two.
	 */
	if(sizeof sa != (size_t)IPaddrlen){
		printf("BAD: the address array is %zu bytes but the copy uses %d;"
			" %zu bytes of the address are lost\n",
			sizeof sa, IPaddrlen, sizeof sa - IPaddrlen);
		bad = 1;
	}

	/*
	 * And the end address must not carry the ~ into the upper half of
	 * each word, for the same reason as the v4 case.
	 */
	for(h = 0; h < IPllen; h++)
		if((ulong)ea[h] >> 32){
			printf("BAD: ea[%d]=%016lx has bits above 32 set\n", h, (ulong)ea[h]);
			bad = 1;
		}
	return bad;
}
EOF

if "$CC" -O2 -o "$BUILD/v6" "$BUILD/v6.c" 2>"$BUILD/v6.log"; then
    OUT="$("$BUILD/v6" 2>&1)"; RC=$?
    info "$OUT"
    if [[ $RC -eq 0 ]]; then
        pass "v6 route address survives the copy out of ulong[IPllen]"
    else
        fail "v6 route addresses are truncated or mis-masked under LP64"
        [[ "$VERBOSE" -eq 0 ]] && echo "$OUT" | sed 's/^/    /'
    fi
else
    fail "v6 test did not compile"
    cat "$BUILD/v6.log" | sed 's/^/    /'
fi

#
# 3. The copy in the source must match the array it copies from.
#
# A source-level check rather than a runtime one: whatever the fix ends
# up being, the byte count must be tied to the array, not to IPaddrlen.
#
# The memmove itself is fine -- IPaddrlen is the right byte count for a
# v6 address. What has to hold is that IPllen elements of the array it
# copies FROM are exactly that many bytes. Checking the declared type
# says so directly, and ip.h carries a compile-time assertion of the
# same identity.
if [[ -n "$V6COPY" ]]; then
    if [[ "$V6TYPE" == "u32int" ]]; then
        pass "v6 addresses are built in u32int[IPllen], so IPaddrlen is the right copy size"
    else
        fail "v6 addresses are built in $V6TYPE[IPllen]; $V6COPY copies the wrong number of bytes"
    fi
else
    skip "could not find v6addroute's address copy in $SRCFILE"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
[[ $FAILED -eq 0 ]]
