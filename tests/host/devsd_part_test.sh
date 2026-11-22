#!/bin/sh
# The native storage device (os/port/devsd.c): a partition is a range of
# its device, whatever the card's or the disk's table says.
#
# The numbers written to sdctl come from an MBR or a GPT, which are the
# card's or the disk's to say: a start of ffffffff arrived as -1, a
# GPT's are 64 bits as they come, and nothing looked at either. A
# negative start made every offset in the partition negative, and the
# part of a block an unaligned read or write copies was then taken from
# before the bounce buffer: the kernel's memory, read and written.
#
# partok is extracted from the source and run: every range it takes
# gives, for every offset in the partition, a block that is not negative
# and a place in it from 0 to 511. The rest is by the order of the
# source: the table is changed only after partok, under the lock I/O
# takes; sdctl's writer gives the card's size; the copy's guard in sdio;
# the second disk's read and write refuse a negative offset and its scan
# leaves out a table entry that is no range; the boot code reads an
# MBR's fields as unsigned.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/port/devsd.c
NVME=$ROOT/os/bcm2712/nvme.c
OSINIT=$ROOT/os/init/osinit.b
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

{ echo 'static int'; awk '/^partok\(/,/^}/' "$SRCFILE"; } > "$BUILD/fn.inc"
grep '^#define[[:space:]]*Maxpartblk' "$SRCFILE" > "$BUILD/def.inc"
if ! grep -q '^partok(' "$BUILD/fn.inc" || ! [ -s "$BUILD/def.inc" ]; then
	fail "devsd.c has no partok (or no Maxpartblk) to run: partitions are taken as written"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <limits.h>
typedef long long vlong;
enum { Blen = 512 };
#include "def.inc"
#include "fn.inc"

static const vlong edge[] = {
	LLONG_MIN, LLONG_MIN+1, -(1LL<<62), -0x100000000LL, -0x80000000LL, -2, -1, 0, 1, 2, 63, 2048,
	0x7fffffffLL, 0x80000000LL, 0xffffffffLL, 0x100000000LL, (1LL<<40), (1LL<<52), (1LL<<53)-1,
	(1LL<<53), (1LL<<53)+1, (1LL<<54), (1LL<<55), (1LL<<62), LLONG_MAX/512, LLONG_MAX/512+1, LLONG_MAX-1, LLONG_MAX,
};
#define N (int)(sizeof edge/sizeof edge[0])

int
main(void)
{
	static const vlong dev[] = {0, 1, 2048, 62333952, (1LL<<32), (1LL<<40)};
	int i, j, k, bad = 0, taken = 0;
	vlong s, n, d, off, len, last;

	for(k = 0; k < (int)(sizeof dev/sizeof dev[0]); k++)
	for(i = 0; i < N; i++)
	for(j = 0; j < N; j++){
		s = edge[i]; n = edge[j]; d = dev[k];
		if(!partok(s, n, d))
			continue;
		taken++;
		/* what the device then computes must be a place on a disk */
		if(s < 0 || n <= 0){
			if(bad++ < 10) printf("  taken: start %lld, %lld blocks\n", s, n);
			continue;
		}
		if(s > LLONG_MAX/Blen || n > LLONG_MAX/Blen || s*Blen > LLONG_MAX - n*Blen){
			if(bad++ < 10) printf("  taken, and its bytes overflow: start %lld, %lld blocks\n", s, n);
			continue;
		}
		off = s*Blen; len = n*Blen; last = off + len - 1;
		if(off/Blen < 0 || off%Blen != 0 || last/Blen < 0 || last%Blen < 0 || last%Blen >= Blen){
			if(bad++ < 10) printf("  taken, a block or a place in it out of range: start %lld, %lld blocks\n", s, n);
		}
		if(d > 0 && s >= d){
			if(bad++ < 10) printf("  taken, starting past a device of %lld blocks: start %lld\n", d, s);
		}
	}
	/* and what a table ordinarily says is taken */
	if(!partok(0, 1, 0) || !partok(2048, 262144, 62333952) || !partok(264192, 62069760, 62333952) ||
	   !partok(0x80000000LL, 0x80000000LL, 0) || !partok(0xffffffffLL, 1, 0) || !partok(0, 62333952, 62333952)){
		printf("  an ordinary partition is refused\n");
		bad++;
	}
	/* the MBR fields that started this: ffffffff read as an int */
	if(partok(-1, 8, 62333952) || partok(8, -1, 62333952) || partok(8, 0, 62333952) ||
	   partok(0x40000000000000LL, 8, 0) || partok(62333952, 8, 62333952)){
		printf("  a range that is none is taken\n");
		bad++;
	}
	printf("%d ranges taken of %d\n", taken, N*N*(int)(sizeof dev/sizeof dev[0]));
	return bad != 0;
}
EOT

if "$CC" -std=c99 -Wall -Wno-unused-function -g -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "a partition is a range of blocks that are not negative, do not overflow, and start on the device ($(tail -1 "$BUILD/run.out"))"
	else
		fail "partok: $(head -5 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# The table is changed only after partok has been asked, under sd.q.
awk '/^addpart\(/,/^}/' "$SRCFILE" > "$BUILD/addpart.c"
ok=$(grep -n 'partok(startblk, nblk, devblks)' "$BUILD/addpart.c" | head -1 | cut -d: -f1)
lk=$(grep -n 'qlock(&sd.q)' "$BUILD/addpart.c" | head -1 | cut -d: -f1)
st=$(grep -n 'p->off = startblk \* Blen' "$BUILD/addpart.c" | head -1 | cut -d: -f1)
if [ -n "$ok" ] && [ -n "$lk" ] && [ -n "$st" ] && [ "$ok" -lt "$lk" ] && [ "$lk" -lt "$st" ] &&
   grep -q 'nblk = devblks - startblk' "$BUILD/addpart.c"; then
	pass "a partition is stored only after it is checked, cut at its device's end, with the I/O lock held"
else
	fail "addpart stores a partition unchecked or unlocked (check ${ok:-none}, lock ${lk:-none}, store ${st:-none})"
fi

# Every way in gives its device's size.
if grep -q 'strtoll(cb->f\[3\], nil, 0), sdblknblocks(), 0)' "$SRCFILE" &&
   ! grep -q 'sdaddpart([^)]*strtoll[^)]*)$' "$SRCFILE" &&
   grep -q 'addpart(name, start, n, nvmelength()/Blen, 1)' "$SRCFILE"; then
	pass "sdctl's writer and the second disk's scan each give the size of their device"
else
	fail "a partition is added with no device size to hold it to"
fi

# sdio refuses what would index before its buffer.
awk '/^sdio\(/,/^}/' "$SRCFILE" > "$BUILD/sdio.c"
g=$(grep -n 'off < 0 || base < 0' "$BUILD/sdio.c" | head -1 | cut -d: -f1)
a=$(grep -n 'off += base' "$BUILD/sdio.c" | head -1 | cut -d: -f1)
if [ -n "$g" ] && [ -n "$a" ] && [ "$g" -lt "$a" ]; then
	pass "the copy through the bounce buffer is never given a negative offset or base"
else
	fail "sdio adds a base to an offset without checking either"
fi

# The second disk.
if [ -f "$NVME" ]; then
	if awk '/^nvmerw\(/,/^}/' "$NVME" | grep -q 'off < 0 || off >= len'; then
		pass "the second disk's read and write refuse a negative offset"
	else
		fail "nvmerw takes a negative offset"
	fi
	if awk '/^gptscan\(/,/^}/' "$NVME" | grep -q 'last < first || last >= nvme.nblocks' &&
	   ! awk '/^gptscan\(/,/^}/' "$NVME" | grep -q 'waserror'; then
		pass "its scan leaves out a table entry that is no range of the disk, and raises nothing at boot"
	else
		fail "gptscan adds a GPT entry as it comes"
	fi
fi

# The boot code reads an MBR's 32-bit fields as unsigned.
if [ -f "$OSINIT" ]; then
	if grep -q 'start := big sec\[p+8\]' "$OSINIT" && grep -q 'nsec := big sec\[p+12\]' "$OSINIT" &&
	   grep -q '"part %s %bd %bd"' "$OSINIT"; then
		pass "the boot code writes an MBR's start and size to sdctl unsigned"
	else
		fail "osinit.b reads an MBR's start or size as a signed int"
	fi
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
