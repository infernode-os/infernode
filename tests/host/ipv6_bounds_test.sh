#!/bin/bash
# Exercise the real IPv6 extension-header walker with malformed packets.

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="$ROOT/os/ip/ipv6.c"
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }
CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)"
[[ -n "$CC" ]] || { echo "SKIP: no C compiler"; exit 0; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

{ echo int; awk '/^unfraglen\(/,/^}/' "$SRCFILE"; } > "$BUILD/unfraglen.inc"
if ! grep -q 'unfraglen' "$BUILD/unfraglen.inc"; then
	echo "ERROR: could not extract unfraglen from $SRCFILE" >&2
	exit 1
fi

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef struct Block Block;
struct Block { uchar *rp; uchar *wp; };

enum { IP6HDR = 40, IP6FHDR = 8, HBH = 0, RH = 43, FH = 44 };

#include "unfraglen.inc"

static int
check(char *name, uchar *packet, int n, int want)
{
	Block b = { packet, packet+n };
	uchar next;
	int got;

	got = unfraglen(&b, &next, 0);
	if(got != want) {
		fprintf(stderr, "%s: got %d, want %d\n", name, got, want);
		return 0;
	}
	return 1;
}

int
main(void)
{
	uchar p[304];
	int ok = 1;

	memset(p, 0, sizeof p);
	p[6] = 17;
	ok &= check("no extension", p, 40, 40);

	memset(p, 0, sizeof p);
	p[6] = HBH;
	ok &= check("missing hop-by-hop header", p, 40, -1);

	memset(p, 0, sizeof p);
	p[6] = HBH;
	p[40] = 17;
	p[41] = 31;
	ok &= check("oversized hop-by-hop header", p, 48, -1);

	memset(p, 0, sizeof p);
	p[6] = FH;
	ok &= check("truncated fragment header", p, 44, -1);

	memset(p, 0, sizeof p);
	p[6] = HBH;
	p[40] = 17;
	p[41] = 0;
	ok &= check("valid hop-by-hop header", p, 48, 48);

	return !ok;
}
EOF

if "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" && "$BUILD/test"; then
	pass "extension walker rejects truncated and oversized headers"
else
	fail "extension walker rejects truncated and oversized headers"
fi

if grep -q 'hl = IP6HDR + nhgets(h->ploadlen)' "$SRCFILE" &&
   grep -q 'if(blocklen(bp) < hl)' "$SRCFILE" &&
   grep -q 'bp = trimblock(bp, 0, hl)' "$SRCFILE"; then
	pass "ingress is constrained to the IPv6 payload length"
else
	fail "ingress is constrained to the IPv6 payload length"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
