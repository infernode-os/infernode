#!/bin/bash
#
# tests/host/ipchecksum_test.sh
#
# Check ptclbsum against known-good checksums.
#
# os/arm64/ipchecksum.c is one of the few files in this port that is
# WRITTEN rather than imported -- upstream implements ptclbsum in
# assembly once per architecture and has no AArch64 version, every os/
# port predating the architecture.
#
# That makes it worth testing more carefully than ported code, for two
# reasons. There is no reference implementation in the tree to diff
# against, and a wrong checksum does not fail loudly: it silently drops
# valid packets or accepts corrupt ones, and presents as an unreliable
# network rather than as a bug in this file.
#
# The vectors are external and checkable: RFC 1071's worked example, and
# a real IPv4 header whose checksum is stated in the packet itself.
#
# As with the other host tests here, it extracts the real function from
# the real source file, so it measures the tree rather than a copy.
#
# Run from project root: ./tests/host/ipchecksum_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="$ROOT/os/arm64/ipchecksum.c"
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

echo -e "${BOLD}ptclbsum against known-good checksums${NC}"
echo ""

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }
CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)"
[[ -n "$CC" ]] || { skip "no C compiler"; echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 0; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# The real function body, lifted out of the real file.
awk '/^ptclbsum\(uchar \*addr, int len\)/,/^}/' "$SRCFILE" > "$BUILD/fn.inc"
if [[ ! -s "$BUILD/fn.inc" ]]; then
    fail "could not extract ptclbsum from $SRCFILE"
    echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 1
fi
info "extracted $(wc -l < "$BUILD/fn.inc" | tr -d ' ') lines from $SRCFILE"

cat > "$BUILD/t.c" <<'EOF'
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned long ulong;

ushort
#include "fn.inc"

static int bad;

static void
check(const char *what, uchar *buf, int len, unsigned want)
{
	unsigned got = ptclbsum(buf, len);

	printf("%-42s sum=%04x want=%04x %s\n", what, got, want,
		got == want ? "ok" : "BAD");
	if(got != want)
		bad = 1;
}

int
main(void)
{
	/*
	 * RFC 1071 section 3, the worked example. The document states the
	 * one's-complement sum of these eight bytes is ddf2, giving a
	 * checksum of 220d.
	 */
	uchar rfc1071[] = {0x00,0x01,0xf2,0x03,0xf4,0xf5,0xf6,0xf7};
	check("RFC 1071 worked example", rfc1071, sizeof rfc1071, 0xddf2);

	/*
	 * A real IPv4 header, checksum field zeroed. The header carries
	 * its own checksum (0xb861), so the sum must be its complement.
	 * 45 00 00 73  00 00 40 00  40 11 [b861] c0a80001 c0a800c7
	 */
	{
		uchar ip4[20] = {
			0x45,0x00,0x00,0x73, 0x00,0x00,0x40,0x00,
			0x40,0x11,0x00,0x00, 0xc0,0xa8,0x00,0x01,
			0xc0,0xa8,0x00,0xc7,
		};
		check("IPv4 header (checksum zeroed)", ip4, sizeof ip4,
			(unsigned)(~0xb861 & 0xffff));
	}

	/*
	 * Odd length. The trailing byte pads on the HIGH side, so 0xAB
	 * alone must sum to 0xAB00 and not 0x00AB. Getting this backwards
	 * is correct for every even-length packet and wrong for every
	 * odd-length one.
	 */
	{
		uchar odd[1] = {0xAB};
		check("single odd byte pads high", odd, 1, 0xAB00);
	}
	{
		uchar odd3[3] = {0x12,0x34,0x56};
		check("odd length (3 bytes)", odd3, 3, 0x1234 + 0x5600);
	}

	/* Empty buffer must be the additive identity. */
	{
		uchar none[1] = {0};
		check("zero length", none, 0, 0);
	}

	/*
	 * Carry folding: two words that overflow 16 bits must wrap the
	 * carry back in rather than truncate it.
	 */
	{
		uchar carry[4] = {0xff,0xff,0xff,0xff};
		/* ffff + ffff = 1fffe -> fffe + 1 = ffff */
		check("carry folds back in", carry, sizeof carry, 0xffff);
	}

	/*
	 * Alignment must not matter: this reads bytes, so the same data
	 * at an odd address must give the same answer. Upstream's
	 * assembly has to special-case that; this must not care.
	 */
	{
		uchar pad[9];
		uchar want[8] = {0x00,0x01,0xf2,0x03,0xf4,0xf5,0xf6,0xf7};
		memcpy(pad+1, want, 8);
		check("same data at an odd address", pad+1, 8, 0xddf2);
	}

	return bad;
}
EOF

if "$CC" -O2 -I"$BUILD" -o "$BUILD/t" "$BUILD/t.c" 2>"$BUILD/cc.log"; then
    OUT="$("$BUILD/t" 2>&1)"; RC=$?
    if [[ "$VERBOSE" -eq 1 ]]; then echo "$OUT" | sed 's/^/  /'; fi
    if [[ $RC -eq 0 ]]; then
        pass "ptclbsum matches every known-good vector"
    else
        fail "ptclbsum disagrees with a known-good checksum"
        echo "$OUT" | grep BAD | sed 's/^/    /'
    fi
else
    fail "test did not compile"
    sed 's/^/    /' "$BUILD/cc.log"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"
[[ $FAILED -eq 0 ]]
