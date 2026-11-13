#!/bin/sh
# Exercise the real ARP retransmit queue and interface-lock helpers.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/arp.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

if [ ! -f "$SRCFILE" ]; then
	echo "ERROR: $SRCFILE not found" >&2
	exit 1
fi
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
{ echo 'static void'; awk '/^arpdropq\(/,/^}/' "$SRCFILE"; } > "$BUILD/helpers.inc"
{ echo 'static int'; awk '/^arpifclock\(/,/^}/' "$SRCFILE"; } >> "$BUILD/helpers.inc"

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>

#define nil ((void*)0)
typedef struct Block Block;
typedef struct Arp Arp;
typedef struct Arpent Arpent;
typedef struct Ipifc Ipifc;
typedef struct RWlock RWlock;

struct Block { Block *list; int id; };
struct Arp { Block *dropf; Block *dropl; };
struct Arpent { int rxtsrem; unsigned int ifcid; };
struct RWlock { int held; };
struct Ipifc { RWlock rwl; unsigned int ifcid; };

static int allowlock;
int canrlock(RWlock *l) { if(!allowlock) return 0; l->held++; return 1; }
void runlock(RWlock *l) { l->held--; }

#include "helpers.inc"

static int
dropcheck(void)
{
	Arp arp = { 0 };
	Block a = { 0, 1 }, b = { 0, 2 }, c = { 0, 3 }, d = { 0, 4 };

	a.list = &b;
	c.list = &d;
	arpdropq(&arp, &a);
	arpdropq(&arp, &c);
	return arp.dropf == &a && a.list == &b && b.list == &c &&
		c.list == &d && arp.dropl == &d;
}

static int
lockcheck(void)
{
	Arpent a = { 0, 7 };
	Ipifc ifc = { { 0 }, 8 };

	allowlock = 1;
	if(arpifclock(&a, &ifc) != 0 || ifc.rwl.held != 0)
		return 0;
	a.rxtsrem = 1;
	allowlock = 0;
	if(arpifclock(&a, &ifc) != 0 || ifc.rwl.held != 0)
		return 0;
	allowlock = 1;
	if(arpifclock(&a, &ifc) != 0 || ifc.rwl.held != 0)
		return 0;
	ifc.ifcid = 7;
	if(arpifclock(&a, &ifc) != 1 || ifc.rwl.held != 1)
		return 0;
	runlock(&ifc.rwl);
	return ifc.rwl.held == 0;
}

int
main(void)
{
	if(!dropcheck()) {
		fprintf(stderr, "drop queue lost or reordered a list\n");
		return 1;
	}
	if(!lockcheck()) {
		fprintf(stderr, "interface read lock was not balanced\n");
		return 1;
	}
	return 0;
}
EOF

if grep -q '^arpdropq(' "$BUILD/helpers.inc" &&
   grep -q '^arpifclock(' "$BUILD/helpers.inc" &&
   "$CC" -std=c99 -Wall -Wextra -Werror -I"$BUILD" "$BUILD/test.c" -o "$BUILD/test" &&
   "$BUILD/test"; then
	pass "retransmit helpers preserve drop lists and balance interface locks"
else
	fail "retransmit helpers preserve drop lists and balance interface locks"
fi

if [ "$(grep -c 'arpdropq(arp, xp)' "$SRCFILE")" -eq 2 ]; then
	pass "both ARP eviction and retransmit expiry use the safe append helper"
else
	fail "both ARP eviction and retransmit expiry use the safe append helper"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
