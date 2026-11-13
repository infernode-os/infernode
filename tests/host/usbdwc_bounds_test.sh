#!/bin/sh
# The Pis' USB host controller (os/bcm/usbdwc.c), which the hosted
# emulator has none of: the lengths it gives the controller and takes
# back from it.
#
# bouncelen, xferlimit and logslot are extracted from the source and
# run: a bounce buffer as long as the whole packets an IN is programmed
# for; a channel operation that fits hctsiz's 19-bit size and 10-bit
# packet count at every packet size; a debug-log slot inside the array
# whatever the count has become. The rest is checked by the order of
# the source: chanio sizing its bounce by bouncelen, chanio1 refusing
# a length or packet size it cannot program before it programs one and
# a DMA pointer that went backwards before counting with it, epread
# copying only a positive count and keeping an outgrown read buffer
# until the endpoint closes.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/bcm/usbdwc.c
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

: > "$BUILD/fns.inc"
for fn in bouncelen xferlimit logslot; do
	{ echo 'static int'; awk "/^$fn\\(/,/^}/" "$SRCFILE"; } >> "$BUILD/fns.inc"
	if ! grep -q "^$fn(" "$BUILD/fns.inc"; then
		fail "usbdwc.c has no $fn to run"
		echo "Passed: $PASSED  Failed: $FAILED"
		exit 1
	fi
done

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>

#define ROUND(s, sz)	(((s)+((sz)-1))/(sz)*(sz))
#define HOWMANY(x, y)	(((x)+((y)-1))/(y))

#include "fns.inc"

static int bad;
static void
want(long got, long expect, const char *what, long a, long b)
{
	if(got != expect){
		if(bad < 10)
			printf("  %s(%ld, %ld): got %ld, want %ld\n", what, a, b, got, expect);
		bad++;
	}
}

int
main(void)
{
	static const int sizes[] = {1, 8, 16, 32, 64, 512, 1024};
	int i, mp, len, lim, n;
	static int log[32];

	/* an IN's buffer holds every packet it is programmed for */
	for(i = 0; i < (int)(sizeof sizes/sizeof sizes[0]); i++){
		mp = sizes[i];
		for(len = 1; len <= 4*mp + 3; len++){
			n = bouncelen(1, len, mp);
			if(n < len || n % mp != 0 || n - len >= mp)
				want(n, ROUND(len, mp), "bouncelen in", len, mp);
			want(bouncelen(0, len, mp), len, "bouncelen out", len, mp);
		}
	}
	want(bouncelen(1, 18, 64), 64, "bouncelen in", 18, 64);
	want(bouncelen(1, 18, 0), 18, "bouncelen in", 18, 0);

	/* a channel operation fits the size and packet-count fields */
	for(mp = -2; mp <= 1100; mp++){
		lim = xferlimit(mp);
		if(mp <= 0 || mp > 1024){
			want(lim, 0, "xferlimit", mp, 0);
			continue;
		}
		if(lim <= 0 || lim > 0x7ffff || HOWMANY(lim, mp) > 0x3ff || lim % mp != 0)
			want(lim, -1, "xferlimit", mp, 0);
		/* and it is the most that does */
		n = lim + mp;
		if(n <= 0x7ffff && HOWMANY(n, mp) <= 0x3ff)
			want(lim, n, "xferlimit not the most", mp, 0);
	}

	/* a log slot is in the array, whatever the count */
	for(n = -5; n < 100; n++){
		i = logslot(n);
		if(i < 0 || i >= 32)
			want(i, -1, "logslot", n, 0);
		else
			log[i] = n;
		if(n >= 0 && n < 32)
			want(i, n, "logslot", n, 0);
	}
	want(logslot(33), 31, "logslot", 33, 0);
	want(logslot(0x7fffffff), 31, "logslot", 0x7fffffff, 0);
	(void)log;
	return bad != 0;
}
EOT

SAN=
if echo 'int main(void){return 0;}' > "$BUILD/san.c" &&
   "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null &&
   "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi

if "$CC" -std=c99 -Wall -Wno-unused-function -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "bounce lengths, transfer limits and log slots at every packet size${SAN:+ (ASan, UBSan)}"
	else
		fail "length helpers: $(head -6 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# chanio allocates its bounce by what will be programmed.
awk '/^chanio\(/,/^}/' "$SRCFILE" > "$BUILD/chanio.c"
if grep -q 'n = bouncelen(dir == Epin, len, ep->maxpkt)' "$BUILD/chanio.c" &&
   grep -q 'dmaalloc(n, CACHELINESZ)' "$BUILD/chanio.c" &&
   ! grep -q 'dmaalloc(len' "$BUILD/chanio.c"; then
	pass "chanio's bounce buffer is as long as the transfer programmed"
else
	fail "chanio allocates its bounce buffer by the length asked for"
fi

# chanio1 refuses what it cannot program, before it programs anything.
awk '/^chanio1\(/,/^}/' "$SRCFILE" > "$BUILD/chanio1.c"
chk=$(grep -n 'n = xferlimit(maxpkt)' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
use=$(grep -n 'hc->hctsiz = n | npkt<<OPktcnt | pid' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
div=$(grep -n 'HOWMANY(len, ep->maxpkt)' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ -n "$div" ] && [ "$chk" -lt "$div" ] && [ "$div" -lt "$use" ] &&
   grep -q 'if(n == 0 || len < 0)' "$BUILD/chanio1.c"; then
	pass "chanio1 checks the packet size and length before dividing by one or programming the other"
else
	fail "chanio1 programs hctsiz without checking what fits it (check ${chk:-none}, divide ${div:-none}, program ${use:-none})"
fi

# A DMA pointer behind where the pass began is an error, not a count.
cnt=$(grep -n 'n = hc->hcdma - hcdma;' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
neg=$(grep -n 'if(n < 0){' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
sub=$(grep -n 'nleft -= n;' "$BUILD/chanio1.c" | head -1 | cut -d: -f1)
if [ -n "$cnt" ] && [ -n "$neg" ] && [ -n "$sub" ] && [ "$cnt" -lt "$neg" ] && [ "$neg" -lt "$sub" ] &&
   awk -v s="$neg" 'NR > s && NR < s + 14' "$BUILD/chanio1.c" | grep -q 'error(Eio)'; then
	pass "a DMA pointer that went backwards ends the transfer before it is counted"
else
	fail "chanio1 counts with a negative DMA difference"
fi

# epread copies only what arrived, and keeps a read buffer it has outgrown.
awk '/^epread\(/,/^}/' "$SRCFILE" > "$BUILD/epread.c"
if awk '/if\(nr > 0\)\{/,/\}/' "$BUILD/epread.c" | grep -q 'memmove(a, p, nr)'; then
	pass "epread copies out only a positive count"
else
	fail "epread copies whatever count the transfer returned"
fi
if grep -q 'epio->retired = b;' "$BUILD/epread.c" && ! grep -q 'freeb(b)' "$BUILD/epread.c" &&
   awk '/^epclose\(/,/^}/' "$SRCFILE" | grep -q 'freeblist(((Epio\*)ep->aux)->retired)'; then
	pass "a read buffer outgrown is kept until the endpoint closes"
else
	fail "epread frees a read buffer an IN may still be written to"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
