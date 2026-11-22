#!/bin/sh
# The Ethernet medium takes an ARP frame only whole and in its own shape,
# keeps only a sender that could be one station, hands IP no frame shorter
# than the medium's header, and wants an interface name to bind to.
#
# The two ARP predicates are extracted from os/ip/ethermedium.c and run;
# the readers and bind are checked by the order of their source.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/ethermedium.c
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

{ echo 'static int'; awk '/^arpframeok\(/,/^}/' "$SRCFILE"; } > "$BUILD/arp.inc"
{ echo 'static int'; awk '/^arpsenderok\(/,/^}/' "$SRCFILE"; } >> "$BUILD/arp.inc"
awk '/^struct Etherarp$/,/^};/' "$SRCFILE" > "$BUILD/etherarp.inc"

if ! grep -q 'arpframeok' "$BUILD/arp.inc" || ! grep -q 'arpsenderok' "$BUILD/arp.inc"; then
	fail "ethermedium.c has no arpframeok/arpsenderok to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char uchar;
typedef struct Etherarp Etherarp;
enum { ETIP4 = 0x0800 };
#include "etherarp.inc"

static unsigned nhgets(uchar *p) { return p[0]<<8 | p[1]; }

#include "arp.inc"

static int bad;
static void
want(int got, int expect, const char *what)
{
	if(got != expect){
		printf("  %s: got %d, want %d\n", what, got, expect);
		bad++;
	}
}

/* A well-formed request, then varied.  The buffer is exactly as long as
 * the frame claims, on the heap, so a read past it is a sanitizer report. */
static uchar*
frame(int n)
{
	static const uchar good[42] = {
		0xff,0xff,0xff,0xff,0xff,0xff, 0x52,0x54,0,0xaa,0xbb,0xcc, 0x08,0x06,
		0,1, 0x08,0, 6, 4, 0,1,
		0x52,0x54,0,0xaa,0xbb,0xcc, 10,0,2,2,
		0,0,0,0,0,0, 10,0,2,15,
	};
	uchar *p = malloc(n > 0 ? n : 1);
	memset(p, 0, n > 0 ? n : 1);
	memcpy(p, good, n < 42 ? n : 42);
	return p;
}

int
main(void)
{
	uchar *p;
	int n;
	uchar mac[6] = {0x52,0x54,0,0xaa,0xbb,0xcc};
	uchar gmac[6] = {0x01,0,0x5e,0,0,1};
	uchar bmac[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
	uchar a[4];

	/* every length short of the fixed structure is refused */
	for(n = 0; n < 42; n++){
		p = frame(n);
		want(arpframeok(p, n), 0, "short frame");
		free(p);
	}
	p = frame(42); want(arpframeok(p, 42), 1, "whole frame"); free(p);
	p = frame(60); want(arpframeok(p, 60), 1, "padded frame"); free(p);

	/* the wrong shape is refused whatever its length */
	p = frame(42); p[15] = 6; want(arpframeok(p, 42), 0, "hardware type"); free(p);
	p = frame(42); p[16] = 0x86; p[17] = 0xdd; want(arpframeok(p, 42), 0, "protocol type"); free(p);
	p = frame(42); p[18] = 5; want(arpframeok(p, 42), 0, "hardware length"); free(p);
	p = frame(42); p[19] = 16; want(arpframeok(p, 42), 0, "protocol length"); free(p);
	p = frame(42); p[18] = 0; p[19] = 0; want(arpframeok(p, 42), 0, "zero lengths"); free(p);

	/* senders */
	a[0]=10; a[1]=0; a[2]=2; a[3]=2;	want(arpsenderok(a, mac), 1, "unicast sender");
	want(arpsenderok(a, gmac), 0, "group hardware address");
	want(arpsenderok(a, bmac), 0, "broadcast hardware address");
	a[0]=0; a[1]=0; a[2]=0; a[3]=0;		want(arpsenderok(a, mac), 0, "unspecified address");
	a[0]=255; a[1]=255; a[2]=255; a[3]=255;	want(arpsenderok(a, mac), 0, "limited broadcast");
	a[0]=224; a[1]=0; a[2]=0; a[3]=251;	want(arpsenderok(a, mac), 0, "class D");
	a[0]=240; a[1]=0; a[2]=0; a[3]=1;	want(arpsenderok(a, mac), 0, "class E");
	a[0]=223; a[1]=255; a[2]=255; a[3]=254;	want(arpsenderok(a, mac), 1, "last class C");
	a[0]=0; a[1]=0; a[2]=0; a[3]=1;		want(arpsenderok(a, mac), 1, "0.0.0.1 is not unspecified");

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
		pass "ARP frames: every short or mis-shaped frame refused, whole ones taken${SAN:+ (ASan, UBSan)}"
	else
		fail "ARP predicates: $(head -5 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# recvarp asks before it reads a field of the frame.
awk '/^recvarp\(/,/^}/' "$SRCFILE" > "$BUILD/recvarp.c"
chk=$(grep -n 'arpframeok(ebp->rp, BLEN(ebp))' "$BUILD/recvarp.c" | head -1 | cut -d: -f1)
use=$(grep -n 'nhgets(e->op)' "$BUILD/recvarp.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ]; then
	pass "recvarp checks the frame before reading its operation"
else
	fail "recvarp reads the frame before checking it (check line ${chk:-none}, use line ${use:-none})"
fi

# A sender is cached only after arpsenderok, on both paths.
n=$(grep -c 'arpenter(' "$BUILD/recvarp.c")
g=$(grep -c 'arpsenderok(e->spa, e->sha)' "$BUILD/recvarp.c")
if [ "$n" -eq 2 ] && [ "$g" -eq 2 ]; then
	pass "both ARP cache entries are gated on a plausible sender"
else
	fail "recvarp: $n arpenter calls, $g sender checks"
fi

# Neither reader moves past a header that is not there.
for fn in etherread4 etherread6; do
	awk "/^$fn\\(/,/^}/" "$SRCFILE" > "$BUILD/$fn.c"
	chk=$(grep -n 'BLEN(bp) < ifc->m->hsize' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	use=$(grep -n 'bp->rp += ifc->m->hsize' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ]; then
		pass "$fn drops a frame shorter than the medium's header"
	else
		fail "$fn advances past the header without a length check"
	fi
done

# bind uses argv[2].
awk '/^etherbind\(/,/^}/' "$SRCFILE" > "$BUILD/bind.c"
if grep -q 'argc < 3' "$BUILD/bind.c" && ! grep -q 'argc < 2' "$BUILD/bind.c"; then
	pass "etherbind requires the interface name it dials"
else
	fail "etherbind accepts a bind with no interface name"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
