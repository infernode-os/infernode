#!/bin/sh
# xHCI (os/port/usbxhci.c): the length a bulk or interrupt transfer's
# TRB is given.
#
# trblen is extracted and run: every length up to the 17-bit field's
# limit is itself; past it a read is the most whole packets that fit,
# at every packet size, and a write is refused. By the order of the
# source, epread and epwrite ask trblen before they queue the TRB, and
# an isochronous period is at least one before anything divides by it.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/port/usbxhci.c
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

{ echo 'static long'; awk '/^trblen\(/,/^}/' "$SRCFILE"; } > "$BUILD/fn.inc"
if ! grep -q '^trblen(' "$BUILD/fn.inc"; then
	fail "usbxhci.c has no trblen to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include "fn.inc"
int
main(void)
{
	static const int sizes[] = {0, 8, 64, 512, 1024, 4096};
	static const long big[] = {0x20000, 0x20001, 0x3ffff, 0x400000, 0x7fffffffL};
	long n, got;
	int i, j, bad = 0;

	for(n = 0; n <= 0x1ffff; n++)
		if(trblen(n, 512, 1) != n || trblen(n, 512, 0) != n){
			if(bad++ < 5) printf("  trblen(%ld) changed a length that fits\n", n);
		}
	if(trblen(-1, 512, 1) != 0 || trblen(-1, 512, 0) != 0){ printf("  a negative length\n"); bad++; }
	for(i = 0; i < (int)(sizeof sizes/sizeof sizes[0]); i++)
		for(j = 0; j < (int)(sizeof big/sizeof big[0]); j++){
			got = trblen(big[j], sizes[i], 1);
			if(got <= 0 || got > 0x1ffff ||
			   (sizes[i] > 0 && sizes[i] <= 1024 && (got % sizes[i] != 0 || got + sizes[i] <= 0x1ffff))){
				if(bad++ < 5) printf("  read of %ld at maxpkt %d cut to %ld\n", big[j], sizes[i], got);
			}
			if(trblen(big[j], sizes[i], 0) == big[j]){
				if(bad++ < 5) printf("  write of %ld at maxpkt %d taken\n", big[j], sizes[i]);
			}
		}
	return bad != 0;
}
EOT
if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" && "$BUILD/test" > "$BUILD/run.out" 2>&1; then
	pass "a transfer's length fits its TRB's 17 bits: a long read cut to whole packets, a long write refused"
else
	fail "trblen: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -5 | tr '\n' ' ')"
fi

for fn in epread epwrite; do
	awk "/^$fn\\(/,/^}/" "$SRCFILE" > "$BUILD/$fn.c"
	ck=$(grep -n 'trblen(n, ep->maxpkt' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	qt=$(grep -n 'queuetd(io->ring, TR_NORMAL' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	if [ -n "$ck" ] && [ -n "$qt" ] && [ "$ck" -lt "$qt" ]; then
		pass "$fn bounds its length before queueing the TRB"
	else
		fail "$fn queues a TRB with whatever length it was given"
	fi
done

awk '/^initisoio\(/,/^}/' "$SRCFILE" > "$BUILD/iso.c"
if grep -A2 'io->period = ep->pollival' "$BUILD/iso.c" | grep -q 'if(io->period < 1)'; then
	pass "an isochronous period is at least one"
else
	fail "initisoio leaves a period of zero for isoread and isowrite to divide by"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
