#!/bin/sh
# The ARP and neighbour cache (os/ip/arp.c): who may enter what, and
# what is put back on the retransmit chain.
#
# rxmtstill is extracted and run over every state. The rest is checked
# by the order of the source: arpenter is told the interface a frame
# was heard on and refuses an entry whose route goes by another, before
# it takes the cache's lock; it copies no more of the caller's hardware
# address than the caller gave; rxmitsols, having let the lock go to
# send a solicitation, puts the entry back on the chain only if it is
# still waiting on the same interface; and every caller that heard a
# frame says where.

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

{ echo 'static int'; awk '/^rxmtstill\(/,/^}/' "$SRCFILE"; } > "$BUILD/fn.inc"
AOK=$(sed -n 's/^[ \t]*AOK[ \t]*=[ \t]*\([0-9]*\),.*/\1/p' "$SRCFILE" | head -1)
AWAIT=$(sed -n 's/^[ \t]*AWAIT[ \t]*=[ \t]*\([0-9]*\),.*/\1/p' "$SRCFILE" | head -1)
if ! grep -q '^rxmtstill(' "$BUILD/fn.inc" || [ -z "$AOK" ] || [ -z "$AWAIT" ]; then
	fail "arp.c has no rxmtstill to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<EOT
#include <stdio.h>
enum { AOK = $AOK, AWAIT = $AWAIT };
#include "fn.inc"
int
main(void)
{
	int st, v4, same, bad = 0, want;
	for(st = 0; st <= 3; st++)
		for(v4 = 0; v4 <= 1; v4++)
			for(same = 0; same <= 1; same++){
				want = st == AWAIT && !v4 && same;
				if(rxmtstill(st, v4, same) != want){
					printf("  rxmtstill(%d, %d, %d) != %d\n", st, v4, same, want);
					bad++;
				}
			}
	return bad != 0;
}
EOT
if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" && "$BUILD/test" > "$BUILD/run.out" 2>&1; then
	pass "only an entry still waiting, for IPv6, on the same interface is one to solicit again"
else
	fail "rxmtstill: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -4 | tr '\n' ' ')"
fi

# rxmitsols: the relink is inside the check made after the lock is retaken.
awk '/^rxmitsols\(/,/^}/' "$SRCFILE" > "$BUILD/rx.c"
un=$(grep -n 'qunlock(&arp->ql);	/\* for icmpns \*/' "$BUILD/rx.c" | head -1 | cut -d: -f1)
lk=$(awk -v s="$un" 'NR > s && /qlock\(&arp->ql\)/ { print NR; exit }' "$BUILD/rx.c")
ck=$(grep -n 'if(rxmtstill(a->state, isv4(a->ip), a->ifc == ifc)){' "$BUILD/rx.c" | head -1 | cut -d: -f1)
rl=$(grep -n 'a->rxtsrem--;' "$BUILD/rx.c" | head -1 | cut -d: -f1)
if [ -n "$un" ] && [ -n "$lk" ] && [ -n "$ck" ] && [ -n "$rl" ] && [ "$lk" -lt "$ck" ] && [ "$ck" -lt "$rl" ]; then
	pass "rxmitsols looks at the entry again after the lock was out, before putting it back on the chain"
else
	fail "rxmitsols puts an entry back on the chain without looking at what it has become (relock ${lk:-none}, check ${ck:-none}, relink ${rl:-none})"
fi

# arpenter: the interface heard on, and the address length, before the lock.
awk '/^arpenter\(/,/^}/' "$SRCFILE" > "$BUILD/enter.c"
hd=$(grep -n 'if(rifc != nil && ifc != rifc)' "$BUILD/enter.c" | head -1 | cut -d: -f1)
ml=$(grep -n 'type->maclen > n' "$BUILD/enter.c" | head -1 | cut -d: -f1)
lk=$(grep -n 'qlock(&arp->ql)' "$BUILD/enter.c" | head -1 | cut -d: -f1)
cp=$(grep -n 'memmove(a->mac, mac, type->maclen)' "$BUILD/enter.c" | head -1 | cut -d: -f1)
if [ -n "$hd" ] && [ -n "$ml" ] && [ -n "$lk" ] && [ -n "$cp" ] && [ "$hd" -lt "$lk" ] && [ "$ml" -lt "$lk" ] && [ "$lk" -lt "$cp" ] &&
   grep -q 'if(ifc == nil)' "$BUILD/enter.c" && grep -q 'type == nil' "$BUILD/enter.c"; then
	pass "arpenter refuses an entry routed by another interface than the one it was heard on, and a hardware address shorter than the medium's"
else
	fail "arpenter enters what any interface heard for any other (heard-on check ${hd:-none}, length check ${ml:-none}, lock ${lk:-none})"
fi

# Every caller that heard a frame names its interface; the one entry this node makes for itself says nil.
e1=$(grep -c 'arpenter(er->f, V4, e->spa, e->sha, sizeof(e->sha), [01], ifc);' "$ROOT/os/ip/ethermedium.c")
e2=$(grep -c 'arpenter(icmp->f, V6, np->[a-z]*, lla, 6, [a-z0-9]*, ipifc);' "$ROOT/os/ip/icmp6.c")
e3=$(grep -c 'arpenter(f, V6, ip, nifc->mac, 6, 0, nil);' "$ROOT/os/ip/ipifc.c")
all=$(cat "$ROOT"/os/ip/*.c | grep -c 'arpenter(.*);')
if [ "$e1" -eq 2 ] && [ "$e2" -eq 2 ] && [ "$e3" -eq 1 ] && [ "$all" -eq 5 ]; then
	pass "ARP and neighbour discovery say which interface heard the frame"
else
	fail "arpenter's callers: ethermedium $e1 of 2, icmp6 $e2 of 2, ipifc $e3 of 1, $all calls in all"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
