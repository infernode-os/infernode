#!/bin/sh
# The Pi 4's gigabit MAC reports each received frame's length in a 12-bit
# field of the descriptor; the driver takes it only when it is one whole
# good frame that fits.  rxframelen is extracted from the driver and run
# over every length, every flag combination and several rooms; the order of
# recvproc and replenish is checked in the source.  No emulator has this
# MAC, so this and the board are the only tests it has.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/bcm2711/ethergenet.c
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

{ echo 'static long'; awk '/^rxframelen\(/,/^}/' "$SRCFILE"; } > "$BUILD/rxlen.inc"
if ! grep -q 'rxframelen' "$BUILD/rxlen.inc"; then
	fail "ethergenet.c has no rxframelen: the descriptor's length is used unchecked"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

# The driver's own constants, so the test cannot drift from them.
for k in Rbsz Maxtu DmaSOP DmaEOP DmaRxLg DmaRxNo DmaRxErr DmaRxCrc DmaRxOv; do
	v=$(awk -v k="$k" '$1 == k && $2 == "=" { sub(/,.*/, "", $3); print $3; exit }' "$SRCFILE")
	[ -n "$v" ] || { fail "cannot find $k in ethergenet.c"; echo "Passed: $PASSED  Failed: $FAILED"; exit 1; }
	echo "#define $k $v"
done > "$BUILD/consts.h"

cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
typedef unsigned int u32int;
enum { ETHERHDRSIZE = 14 };
#include "consts.h"
#define DmaRxErrors (DmaRxLg|DmaRxNo|DmaRxErr|DmaRxCrc|DmaRxOv)
#include "rxlen.inc"

int
main(void)
{
	static const long rooms[] = { 0, 13, 14, 64, Maxtu-1, Maxtu, Rbsz, Rbsz+64, Rbsz+127 };
	static const u32int flags[] = {
		DmaSOP|DmaEOP, DmaSOP, DmaEOP, 0,
		DmaSOP|DmaEOP|DmaRxLg, DmaSOP|DmaEOP|DmaRxNo, DmaSOP|DmaEOP|DmaRxErr,
		DmaSOP|DmaEOP|DmaRxCrc, DmaSOP|DmaEOP|DmaRxOv,
	};
	unsigned r, f;
	long len, got, room;
	int bad = 0, taken = 0;

	for(r = 0; r < sizeof rooms/sizeof rooms[0]; r++)
	for(f = 0; f < sizeof flags/sizeof flags[0]; f++)
	for(len = 0; len < 4096; len++){
		room = rooms[r];
		got = rxframelen(flags[f] | (u32int)len<<16, room);
		if(flags[f] == (DmaSOP|DmaEOP) && len >= ETHERHDRSIZE && len <= Maxtu && len <= room){
			if(got != len){
				if(bad++ < 5) printf("  good frame len %ld room %ld refused (%ld)\n", len, room, got);
			}else
				taken++;
		}else if(got != -1){
			if(bad++ < 5) printf("  flags %#x len %ld room %ld taken as %ld\n", flags[f], len, room, got);
		}
		/* whatever it says, it never exceeds the room or the buffer */
		if(got > room || got > Rbsz){
			if(bad++ < 5) printf("  len %ld room %ld: %ld is past the block\n", len, room, got);
		}
	}
	/* bits above the length field do not leak into it */
	if(rxframelen(DmaSOP|DmaEOP | 60<<16 | 0xF0000000u, Rbsz) != 60){
		printf("  status bits above the field changed the length\n");
		bad++;
	}
	printf("%d taken\n", taken);
	return bad != 0 || taken == 0;
}
EOF

if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "rxframelen: all 4096 lengths under every flag and room; only whole frames that fit are taken ($(tail -1 "$BUILD/run.out"))"
	else
		fail "rxframelen: $(head -5 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

# recvproc moves wp only by what rxframelen returned, against the block's own room.
awk '/^recvproc\(/,/^}/' "$SRCFILE" > "$BUILD/recvproc.c"
if grep -q 'len = rxframelen(s, b->lim - b->rp);' "$BUILD/recvproc.c" &&
   grep -q 'b->wp += len;' "$BUILD/recvproc.c" &&
   ! grep -q 'b->wp += (s' "$BUILD/recvproc.c"; then
	pass "recvproc advances the block only by a checked length"
else
	fail "recvproc advances the block by the descriptor's raw length"
fi

# replenish leaves the slot's block in place until it has another.
awk '/^replenish\(/,/^}/' "$SRCFILE" > "$BUILD/replenish.c"
if grep -q 'while((nb = newrxblock()) == nil)' "$BUILD/replenish.c" &&
   ! grep -q 'while((d->b = newrxblock()) == nil)' "$BUILD/replenish.c"; then
	pass "replenish never leaves a ring slot empty while it waits"
else
	fail "replenish clears the ring slot before it has a block for it"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
