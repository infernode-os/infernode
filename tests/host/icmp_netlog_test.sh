#!/bin/sh
# ICMPv4 believes the IP header's total length only between an ICMP header's
# worth and what was received, quotes a packet in an error only when the
# quoted bytes are there, and answers an echo only when it was sent to this
# node itself.  The network log leaves the error stack as it found it,
# refuses an open it has no buffer for, and writes only while it is open.
#
# icmplenok is extracted from os/ip/icmp.c and run over every pair of
# lengths; the rest is checked by the order of the source.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
ICMP=$ROOT/os/ip/icmp.c
NETLOG=$ROOT/os/ip/netlog.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$ICMP" "$NETLOG"; do
	[ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{ echo 'static int'; awk '/^icmplenok\(/,/^}/' "$ICMP"; } > "$BUILD/len.inc"
if grep -q 'icmplenok' "$BUILD/len.inc"; then
	cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
enum { ICMP_IPSIZE = 20, ICMP_HDRSIZE = 8 };
#include "len.inc"
int
main(void)
{
	int n, iplen, bad = 0, ok = 0;
	for(n = 0; n <= 2048; n++)
	for(iplen = -4; iplen <= 2052; iplen++){
		int want = n >= 28 && iplen >= 28 && iplen <= n;
		if(icmplenok(n, iplen) != want){
			if(bad++ < 5) printf("  received %d declared %d: %d\n", n, iplen, !want);
		}else if(want)
			ok++;
	}
	/* a 16-bit length field's whole range against a full-size frame */
	for(iplen = 0; iplen <= 65535; iplen++)
		if(icmplenok(1500, iplen) != (iplen >= 28 && iplen <= 1500))
			bad++;
	printf("%d accepted\n", ok);
	return bad != 0 || ok == 0;
}
EOF
	if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" &&
	   "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "icmplenok: every received and declared length; nothing under an ICMP header or over the packet ($(tail -1 "$BUILD/run.out"))"
	else
		fail "icmplenok: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -4 | tr '\n' ' ')"
	fi
else
	fail "icmp.c has no icmplenok: the declared length has no lower bound"
fi

awk '/^icmpiput\(/,/^}/' "$ICMP" > "$BUILD/iput.c"

# No field of the header is read, even to log it, before the length is known.
chk=$(grep -n 'n < ICMP_IPSIZE+ICMP_HDRSIZE' "$BUILD/iput.c" | head -1 | cut -d: -f1)
use=$(grep -n 'p->type' "$BUILD/iput.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ] && grep -q 'icmplenok(n, iplen)' "$BUILD/iput.c"; then
	pass "icmpiput checks both lengths before reading the ICMP header"
else
	fail "icmpiput reads the ICMP header before it knows it is there"
fi

# An echo is answered only when sent to this node.
awk '/case EchoRequest:/,/case Unreachable:/' "$BUILD/iput.c" > "$BUILD/echo.c"
chk=$(grep -n '& Runi' "$BUILD/echo.c" | head -1 | cut -d: -f1)
use=$(grep -n 'mkechoreply' "$BUILD/echo.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ]; then
	pass "an echo to a broadcast or group address is not answered"
else
	fail "an echo is answered whatever it was sent to"
fi

# Both error generators know the quoted bytes are there before copying them.
ok=1
for fn in icmpttlexceeded icmpunreachable; do
	awk "/^$fn\\(/,/^}/" "$ICMP" > "$BUILD/$fn.c"
	chk=$(grep -n 'BLEN(bp) < ICMP_IPSIZE + 8' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	use=$(grep -n 'memmove(np->data, bp->rp, ICMP_IPSIZE + 8)' "$BUILD/$fn.c" | head -1 | cut -d: -f1)
	[ -n "$chk" ] && [ -n "$use" ] && [ "$chk" -lt "$use" ] || ok=0
done
if [ $ok = 1 ] && grep -q 'Runi' "$BUILD/icmpttlexceeded.c"; then
	pass "ICMP errors quote only bytes that were received, and go to one node"
else
	fail "an ICMP error quotes eight bytes that may not have been received"
fi

# netlogctl: every return has popped the error label it pushed.
awk '/^netlogctl\(/,/^}/' "$NETLOG" > "$BUILD/ctl.c"
if awk '
	/waserror\(\)/ { pushed=1 }
	/poperror\(\);/ { popped=NR }
	/^[ \t]*return;/ { if(pushed && popped != NR-1) bad=1 }
	END { exit bad }' "$BUILD/ctl.c"; then
	pass "netlogctl pops its error label on every return"
else
	fail "netlogctl returns with its error label still pushed"
fi

# netlogopen refuses an open it has no buffer for, and starts empty.
awk '/^netlogopen\(/,/^}/' "$NETLOG" > "$BUILD/open.c"
if grep -q 'error(Enomem)' "$BUILD/open.c" && grep -q 'f->alog->len = 0' "$BUILD/open.c"; then
	pass "netlogopen fails without a buffer and starts with an empty log"
else
	fail "netlogopen goes on with no buffer, or keeps the last opening's length"
fi

# netlog looks again under the lock; close leaves nothing pointing at the buffer.
awk '/^netlog\(/,/^}/' "$NETLOG" > "$BUILD/log.c"
awk '/^netlogclose\(/,/^}/' "$NETLOG" > "$BUILD/close.c"
lk=$(grep -n 'lock(&f->alog->lk)' "$BUILD/log.c" | head -1 | cut -d: -f1)
chk=$(grep -n 'f->alog->opens == 0 || f->alog->buf == nil' "$BUILD/log.c" | head -1 | cut -d: -f1)
use=$(grep -n 'f->alog->rptr + f->alog->len' "$BUILD/log.c" | head -1 | cut -d: -f1)
if [ -n "$lk" ] && [ -n "$chk" ] && [ -n "$use" ] && [ "$lk" -lt "$chk" ] && [ "$chk" -lt "$use" ] &&
   grep -q 'f->alog->rptr = nil' "$BUILD/close.c" && grep -q 'f->alog->len = 0' "$BUILD/close.c"; then
	pass "netlog writes only while open, checked under the lock; close clears the ring"
else
	fail "netlog can write into a buffer the last close freed"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
