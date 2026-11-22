#!/bin/sh
# os/ip/ipaux.c: ptclcsum, the checksum over a chain of Blocks every
# protocol's input calls with lengths it worked out from headers, and
# the Ethernet address format.
#
# ptclcsum is extracted and run on heap Blocks exactly as long as their
# data, under ASan and UBSan: sums of one block and of a chain cut at
# every point agree with a byte-by-byte reference, a length past the
# data is cut to it, and a negative length or offset reads nothing and
# answers a sum that does not verify (it read before the block, or
# summed a count that was not one). The %E format takes its six bytes
# as the ints they are passed as.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/ipaux.c
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

{ echo 'static ushort'; awk '/^ptclcsum\(/,/^}/' "$SRCFILE"; } > "$BUILD/fn.inc"
if ! grep -q '^ptclcsum(' "$BUILD/fn.inc"; then
	fail "ipaux.c has no ptclcsum to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned long ulong;
typedef struct Block Block;
struct Block { Block *next; uchar *rp; uchar *wp; };
#define BLEN(b)	((b)->wp - (b)->rp)
#define nil ((void*)0)

/* the one's complement sum of n bytes, as the kernel's ptclbsum gives it */
static ushort
ptclbsum(uchar *p, int n)
{
	ulong s = 0;
	int i;
	for(i = 0; i + 1 < n; i += 2)
		s += p[i]<<8 | p[i+1];
	if(i < n)
		s += p[i]<<8;
	while(s >> 16)
		s = (s & 0xffff) + (s >> 16);
	return s;
}

#include "fn.inc"

static Block*
mk(uchar *d, int n)
{
	Block *b = malloc(sizeof *b);
	b->rp = malloc(n > 0 ? n : 1);	/* exactly as long as its data: a read past it is a report */
	memcpy(b->rp, d, n);
	b->wp = b->rp + n;
	b->next = nil;
	return b;
}

static void
rm(Block *b)
{
	Block *n;
	for(; b != nil; b = n){ n = b->next; free(b->rp); free(b); }
}

int
main(void)
{
	uchar d[64];
	Block *b, *c;
	int i, cut, bad = 0;
	ushort ref, got;

	for(i = 0; i < 64; i++)
		d[i] = i*37 + 11;
	ref = ~ptclbsum(d, 64) & 0xffff;

	b = mk(d, 64);
	got = ptclcsum(b, 0, 64);
	if(got != ref){ printf("  one block: %#x, want %#x\n", got, ref); bad++; }
	got = ptclcsum(b, 0, 1000);
	if(got != ref){ printf("  a length past the data: %#x, want %#x\n", got, ref); bad++; }
	got = ptclcsum(b, 0, -1);
	if(got != 0xffff){ printf("  a negative length: %#x, want 0xffff\n", got); bad++; }
	got = ptclcsum(b, 0, -2147483647 - 1);
	if(got != 0xffff){ printf("  the most negative length: %#x, want 0xffff\n", got); bad++; }
	got = ptclcsum(b, -1, 8);
	if(got != 0xffff){ printf("  a negative offset: %#x, want 0xffff\n", got); bad++; }
	got = ptclcsum(b, -4096, 64);
	if(got != 0xffff){ printf("  a large negative offset: %#x, want 0xffff\n", got); bad++; }
	rm(b);

	/* a chain cut at every even point sums as the whole */
	for(cut = 2; cut < 64; cut += 2){
		b = mk(d, cut);
		c = mk(d + cut, 64 - cut);
		b->next = c;
		got = ptclcsum(b, 0, 64);
		if(got != ref){ if(bad++ < 8) printf("  chain cut at %d: %#x, want %#x\n", cut, got, ref); }
		if(ptclcsum(b, 0, -5) != 0xffff){ if(bad++ < 8) printf("  chain, negative length\n"); }
		if(ptclcsum(b, -3, 64) != 0xffff){ if(bad++ < 8) printf("  chain, negative offset\n"); }
		rm(b);
	}
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
		pass "ptclcsum sums a block and a chain, cuts a long length, and reads nothing for a negative one${SAN:+ (ASan, UBSan)}"
	else
		fail "ptclcsum: $(head -6 "$BUILD/run.out" | tr '\n' ' ' | cut -c1-400)"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# %E: six bytes passed as ints are read as ints.
if grep -q 'efmt = "%.2ux%.2ux%.2ux%.2ux%.2ux%.2ux"' "$SRCFILE" && ! grep -q '%\.2lux' "$SRCFILE"; then
	pass "the Ethernet address format reads its bytes at the width they are passed"
else
	fail "eipfmt reads each int-sized byte of an Ethernet address as a long"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
