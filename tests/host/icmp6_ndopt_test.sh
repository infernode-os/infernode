#!/bin/sh
# ICMPv6 reads a Neighbor Discovery option only from a chain that is whole,
# learns a link-layer address only from an option of the right type and
# size, frees every block it is done with, and hands an error's embedded
# packet to a protocol only when the header that protocol reads is there.
#
# The option walkers are extracted from os/ip/icmp6.c and run, on heap
# buffers exactly as long as the options, under ASan where the compiler has
# it; the rest is checked by the order of the source.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/icmp6.c
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

{ echo 'static int'; awk '/^ndoptsok\(/,/^}/' "$SRCFILE"
  echo 'static uchar*'; awk '/^ndoptfind\(/,/^}/' "$SRCFILE"
  echo 'static uchar*'; awk '/^ndlladdr\(/,/^}/' "$SRCFILE"; } > "$BUILD/ndopt.inc"
if ! grep -q 'ndoptsok' "$BUILD/ndopt.inc" || ! grep -q 'ndlladdr' "$BUILD/ndopt.inc"; then
	fail "icmp6.c has no ndoptsok/ndlladdr: options are read unchecked"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned char uchar;
#define nil ((void*)0)
#include "ndopt.inc"

static int bad;
static void
want(long got, long expect, const char *what)
{
	if(got != expect){
		if(bad++ < 8) printf("  %s: got %ld, want %ld\n", what, got, expect);
	}
}

/* options on the heap, exactly n bytes: a read past them is a report */
static uchar*
heap(const uchar *src, long n)
{
	uchar *p = malloc(n > 0 ? n : 1);
	if(n > 0) memcpy(p, src, n);
	return p;
}

/* the definition, written again: whole chain or not */
static int
refok(const uchar *o, long n)
{
	long i = 0;
	while(i < n){
		if(n - i < 2) return 0;
		if(o[i+1] == 0) return 0;
		if(8L*o[i+1] > n - i) return 0;
		i += 8L*o[i+1];
	}
	return i == n;
}

int
main(void)
{
	static const uchar lla[8] = { 1, 1, 0x52,0x54,0,0xaa,0xbb,0xcc };
	static const uchar tlla[8] = { 2, 1, 0x52,0x54,0,0xaa,0xbb,0xcc };
	uchar buf[64], *p, *r;
	long n, i;
	unsigned seed = 12345;

	/* none at all */
	p = heap(lla, 0);
	want(ndoptsok(p, 0), 1, "no options");
	want(ndlladdr(p, 0, 1) == nil, 1, "no options, no address");
	want(ndoptsok(p, -8), 0, "negative room");
	want(ndlladdr(p, -8, 1) == nil, 1, "negative room, no address");
	free(p);

	/* one address option, at every length short of whole */
	for(n = 1; n < 8; n++){
		p = heap(lla, n);
		want(ndoptsok(p, n), 0, "cut option");
		want(ndlladdr(p, n, 1) == nil, 1, "cut option gives no address");
		free(p);
	}
	p = heap(lla, 8);
	want(ndoptsok(p, 8), 1, "whole option");
	r = ndlladdr(p, 8, 1);
	want(r == p+2, 1, "address is the option's six bytes");
	want(ndlladdr(p, 8, 2) == nil, 1, "source option is no target address");
	free(p);

	/* zero length never ends */
	memcpy(buf, lla, 8); buf[1] = 0;
	p = heap(buf, 8);
	want(ndoptsok(p, 8), 0, "zero-length option");
	want(ndlladdr(p, 8, 1) == nil, 1, "zero-length option gives no address");
	free(p);

	/* claims more than was sent */
	memcpy(buf, lla, 8); buf[1] = 2;
	p = heap(buf, 8);
	want(ndoptsok(p, 8), 0, "option longer than the packet");
	want(ndlladdr(p, 8, 1) == nil, 1, "overlong option gives no address");
	free(p);

	/* an address option of two units is not a six-byte address */
	memset(buf, 0, 16); buf[0] = 1; buf[1] = 2;
	p = heap(buf, 16);
	want(ndoptsok(p, 16), 1, "two-unit option is a whole chain");
	want(ndlladdr(p, 16, 1) == nil, 1, "two-unit option is no Ethernet address");
	free(p);

	/* another type first, then the address */
	memset(buf, 0, 24); buf[0] = 14; buf[1] = 1; memcpy(buf+8, tlla, 8); buf[16] = 5; buf[17] = 1;
	p = heap(buf, 24);
	want(ndoptsok(p, 24), 1, "three options");
	want(ndlladdr(p, 24, 2) == p+10, 1, "address found behind another option");
	want(ndlladdr(p, 24, 1) == nil, 1, "type not present");
	free(p);

	/* an address behind a broken option is not reached */
	memset(buf, 0, 16); buf[0] = 14; buf[1] = 0; memcpy(buf+8, tlla, 8);
	p = heap(buf, 16);
	want(ndlladdr(p, 16, 2) == nil, 1, "nothing read past a broken option");
	free(p);

	/* random chains against the definition, each on its own exact buffer */
	for(i = 0; i < 200000; i++){
		long j;
		seed = seed*1103515245u + 12345u; n = (seed>>16) % 41;
		for(j = 0; j < n; j++){
			seed = seed*1103515245u + 12345u;
			buf[j] = (seed>>16) & ((j&7) == 1 ? 3 : 0xff);	/* small lengths, so chains happen */
		}
		p = heap(buf, n);
		want(ndoptsok(p, n), refok(buf, n), "random chain");
		r = ndlladdr(p, n, 1);
		if(r != nil && (r < p+2 || r+6 > p+n)){ if(bad++ < 8) printf("  address outside the options\n"); }
		free(p);
	}
	return bad != 0;
}
EOF

SAN=
if echo 'int main(void){return 0;}' > "$BUILD/san.c" &&
   "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null &&
   "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
if "$CC" -std=c99 -Wall -Wno-unused-function -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "ND options: cut, zero-length, overlong and mis-sized options refused; 200000 random chains agree with the definition${SAN:+ (ASan, UBSan)}"
	else
		fail "ND option walkers: $(head -6 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

awk '/^valid\(/,/^}/' "$SRCFILE" > "$BUILD/valid.c"
awk '/^icmpiput6\(/,/^}/' "$SRCFILE" > "$BUILD/iput.c"

# Every Neighbor Discovery type's options are checked as a chain.
n=$(grep -c 'ndoptsok(' "$BUILD/valid.c")
if [ "$n" -ge 4 ] && ! grep -q 'to be filled in' "$BUILD/valid.c"; then
	pass "valid checks the option chain of NS/NA, RA, RS and Redirect"
else
	fail "valid checks $n option chains; Redirect unchecked or a type missing"
fi

# valid judges the packet by its declared length, and only as one block.
if grep -q 'pktsz != n' "$BUILD/valid.c" && grep -q 'bp->wp = bp->rp + pktsz' "$BUILD/valid.c"; then
	pass "valid reads one block, trimmed to the declared length"
else
	fail "valid reads the header without knowing it is in the first block"
fi

# A neighbour is learned only from ndlladdr's six bytes.
n=$(grep -c 'arpenter(' "$BUILD/iput.c")
g=$(grep -c 'lla, 6,' "$BUILD/iput.c")
if [ "$n" -eq 2 ] && [ "$g" -eq 2 ] && ! grep -q 'np->lnaddr' "$BUILD/iput.c"; then
	pass "NS and NA learn a neighbour only from a checked address option"
else
	fail "icmpiput6 enters a neighbour from unchecked option bytes ($n entries, $g checked)"
fi

# The solicitation is freed whether or not it is answered.
awk '/case NbrSolicit:/,/case NbrAdvert:/' "$BUILD/iput.c" > "$BUILD/ns.c"
if awk '/icmpna\(/ { seen=1 } seen && /else/ { bad=1 } END { exit bad }' "$BUILD/ns.c" &&
   grep -A6 'icmpna(' "$BUILD/ns.c" | grep -q 'freeblist(bp);'; then
	pass "an answered solicitation's block is freed"
else
	fail "an answered solicitation's block is not freed"
fi

# The embedded packet of an error is long enough for the adviser's header.
n=$(grep -c 'BLEN(bp) < sizeof(IPICMP)' "$BUILD/iput.c")
if [ "$n" -eq 2 ] && ! grep -q 'blocklen(bp) < 8' "$BUILD/iput.c"; then
	pass "unreachable and time-exceeded hand on only a whole embedded header"
else
	fail "an 8-byte embedded packet reaches a protocol's adviser"
fi
awk '/^icmpadvise6\(/,/^}/' "$SRCFILE" > "$BUILD/advise.c"
chk=$(grep -n 'BLEN(bp) < sizeof(IPICMP)' "$BUILD/advise.c" | head -1 | cut -d: -f1)
use=$(grep -n 'nhgets(p->icmpid)' "$BUILD/advise.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ]; then
	pass "icmpadvise6 checks the length before reading the header"
else
	fail "icmpadvise6 reads the header unchecked"
fi

# The two error generators free their reply when there is no source for it.
ok=1
for fn in icmpttlexceeded6 icmppkttoobig6; do
	awk "/^$fn\\(/,/^}/" "$SRCFILE" > "$BUILD/$fn.c"
	grep -q 'canrlock(&ifc->rwl)' "$BUILD/$fn.c" && grep -A4 'if(!local)' "$BUILD/$fn.c" | grep -q 'freeblist(nbp);' || ok=0
done
if [ $ok = 1 ]; then
	pass "ttl-exceeded and packet-too-big free their reply and walk addresses under the lock"
else
	fail "ttl-exceeded or packet-too-big leaks its reply block"
fi

# An echo is answered only to one node, from one of ours.
awk '/case EchoRequestV6:/,/case UnreachableV6:/' "$BUILD/iput.c" > "$BUILD/echo.c"
if grep -q 'isv6mcast(p->src)' "$BUILD/echo.c" && grep -q 'isv6mcast(p->dst)' "$BUILD/echo.c"; then
	pass "echo replies have a unicast source and destination"
else
	fail "echo replies reflect a multicast or unspecified address"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
