#!/bin/sh
# What a virtio device puts in the used ring is believed only as far as the
# driver's own records agree.  The head was already checked; this is the
# length: cut to what the chain lent the device to write in.  A queue's
# size is a power of two or the queue is refused; the used entry is read
# after a barrier, once; the network driver takes a frame only from an
# Ethernet header up.
#
# vqsizeok and vqusedlen are extracted from os/virtio/virtio.c and run; the
# rest is checked by the order of the source.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
VIRTIO=$ROOT/os/virtio/virtio.c
ETHER=$ROOT/os/virtio/ethervirtio.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$VIRTIO" "$ETHER"; do
	[ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{ echo 'static int'; awk '/^vqsizeok\(/,/^}/' "$VIRTIO"
  echo 'static u32int'; awk '/^vqusedlen\(/,/^}/' "$VIRTIO"; } > "$BUILD/vq.inc"
if grep -q 'vqsizeok' "$BUILD/vq.inc" && grep -q 'vqusedlen' "$BUILD/vq.inc"; then
	cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
typedef unsigned int u32int;
#include "vq.inc"
int
main(void)
{
	u32int n, lent, len;
	int bad = 0, i, pow;
	static const u32int lens[] = { 0, 1, 11, 12, 13, 14, 1514, 1526, 1530, 4096, 65535, 65536, 0x7FFFFFFF, 0x80000000u, 0xFFFFFFFEu, 0xFFFFFFFFu };

	for(n = 0; n <= 70000; n++){
		pow = 0;
		for(i = 0; i < 32; i++)
			if(n == (u32int)1<<i) pow = 1;
		if(vqsizeok(n) != pow){ if(bad++ < 5) printf("  size %u: %d\n", n, !pow); }
	}
	if(!vqsizeok(0x80000000u) || vqsizeok(0xFFFFFFFFu) || vqsizeok(3) || vqsizeok(0)){ printf("  size edges\n"); bad++; }

	for(i = 0; i < (int)(sizeof lens/sizeof lens[0]); i++)
	for(lent = 0; lent <= 4096; lent += (lent < 64 ? 1 : 97)){
		len = vqusedlen(lens[i], lent);
		if(len > lent || len > lens[i] || (lens[i] <= lent && len != lens[i])){
			if(bad++ < 5) printf("  said %u, lent %u: %u\n", lens[i], lent, len);
		}
	}
	return bad != 0;
}
EOF
	if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" &&
	   "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "a used length never exceeds what was lent; only powers of two are queue sizes"
	else
		fail "vqsizeok/vqusedlen: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -4 | tr '\n' ' ')"
	fi
else
	fail "virtio.c has no vqsizeok/vqusedlen: the device's length and queue size are taken as given"
fi

awk '/^vqsubmit\(/,/^}/' "$VIRTIO" > "$BUILD/submit.c"
awk '/^vqcollect\(/,/^}/' "$VIRTIO" > "$BUILD/collect.c"
awk '/^virtioqueue\(/,/^}/' "$VIRTIO" > "$BUILD/queue.c"

# submit records what the device may write; collect gives back no more.
if grep -q 'q->wlen\[head\] =' "$BUILD/submit.c" &&
   grep -q '\*lenp = vqusedlen(len, q->wlen\[head\]);' "$BUILD/collect.c" &&
   ! grep -q '\*lenp = e->len' "$BUILD/collect.c"; then
	pass "vqcollect returns the device's length cut to the chain's writable bytes"
else
	fail "vqcollect returns the device's length as given"
fi

# the index, a barrier, then the entry, read once.
idx=$(grep -n 'q->lastused == q->used->idx' "$BUILD/collect.c" | tail -1 | cut -d: -f1)
bar=$(awk -v s="$idx" 'NR > s && /coherence\(\);/ { print NR; exit }' "$BUILD/collect.c")
ent=$(grep -n 'e = &q->used->ring' "$BUILD/collect.c" | head -1 | cut -d: -f1)
if [ -n "$idx" ] && [ -n "$bar" ] && [ -n "$ent" ] && [ "$bar" -lt "$ent" ] &&
   [ "$(grep -c 'e->len' "$BUILD/collect.c")" -eq 1 ] && [ "$(grep -c 'e->id' "$BUILD/collect.c")" -eq 1 ]; then
	pass "vqcollect reads the used entry after a barrier, once"
else
	fail "vqcollect reads the used entry with nothing ordering it after the index"
fi

# the queue is refused unless its size is a power of two, and is whole before the device has it.
chk=$(grep -n 'vqsizeok(max)' "$BUILD/queue.c" | head -1 | cut -d: -f1)
reg=$(grep -n 'REG(d, Vrqnum) = n' "$BUILD/queue.c" | head -1 | cut -d: -f1)
bar=$(awk -v r="$reg" 'NR < r && /coherence\(\);/ { last=NR } END { print last }' "$BUILD/queue.c")
init=$(grep -n 'q->lastused = 0' "$BUILD/queue.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$reg" ] && [ -n "$bar" ] && [ -n "$init" ] && [ "$chk" -lt "$reg" ] && [ "$bar" -gt "$init" ]; then
	pass "virtioqueue refuses a size that is no power of two and orders its memory before the hand-over"
else
	fail "virtioqueue takes the device's queue size as given"
fi

# the network driver takes nothing shorter than an Ethernet header.
if grep -q 'len < (u32int)(c->hdrlen + ETHERHDRSIZE)' "$ETHER" && ! grep -q 'len <= (u32int)c->hdrlen ||' "$ETHER"; then
	pass "virtio-net drops a frame shorter than an Ethernet header"
else
	fail "virtio-net hands up a frame shorter than an Ethernet header"
fi

# A receive queue left short of buffers is refilled on the clock, not only on an interrupt.
awk '/^netproc\(/,/^}/' "$ROOT/os/virtio/ethervirtio.c" > "$BUILD/netproc.c"
if grep -q 'starved = vqroom(c->rx) > 0;' "$BUILD/netproc.c" &&
   grep -A1 'if(starved)' "$BUILD/netproc.c" | grep -q 'tsleep(&c->r, network, c, Rxretryms)'; then
	pass "virtio-net retries a receive buffer it could not post, with no frame needed to wake it"
else
	fail "virtio-net waits for an interrupt to refill a receive queue that may have nothing left to interrupt for"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
