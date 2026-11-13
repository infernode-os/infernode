#!/bin/sh
# UDP input (os/ip/udp.c): a datagram's own length is checked against
# what arrived before it is used for anything, and an ICMP error's
# quoted packet is read no further than it goes.
#
# udplenok is extracted from the source and run over every length a
# 16-bit field holds against several amounts received. The rest is
# checked by the order of the source: both versions ask udplenok
# before the checksum runs over that many bytes and before a
# conversation is looked up or made; nothing on the input path leaves
# without freeing its block (a short length once did, after a
# conversation had matched); udpadvise checks the quoted packet's
# length for the version it claims before reading addresses and
# ports; a write too long for the 16-bit length is not sent.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/udp.c
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

{ echo 'static int'; awk '/^udplenok\(/,/^}/' "$SRCFILE"; } > "$BUILD/fn.inc"
if ! grep -q '^udplenok(' "$BUILD/fn.inc"; then
	fail "udp.c has no udplenok to run"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
enum { UDP_UDPHDR_SZ = 8 };
#include "fn.inc"

int
main(void)
{
	static const int avail[] = {-20, -1, 0, 7, 8, 9, 28, 1472, 65507, 65535};
	int i, len, bad = 0, want;

	for(i = 0; i < (int)(sizeof avail/sizeof avail[0]); i++)
		for(len = 0; len <= 65535; len++){
			want = len >= 8 && len <= avail[i];
			if(udplenok(len, avail[i]) != want){
				if(bad++ < 10)
					printf("  udplenok(%d, %d) = %d, want %d\n", len, avail[i], !want, want);
			}
		}
	return bad != 0;
}
EOT

if "$CC" -std=c99 -Wall -Wno-unused-function -g -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "a datagram's length is taken only from a UDP header up to what arrived"
	else
		fail "udplenok: $(head -5 "$BUILD/run.out" | tr '\n' ' ')"
	fi
else
	fail "test did not compile: $(head -3 "$BUILD/cc.err" | tr '\n' ' ')"
fi

awk '/^udpiput\(/,/^}/' "$SRCFILE" > "$BUILD/iput.c"

# Both versions ask before the checksum and before any conversation.
n=$(grep -c 'udplenok(len, blocklen(bp) - UDP[46]_IPHDR_SZ)' "$BUILD/iput.c")
c4=$(grep -n 'udplenok(len, blocklen(bp) - UDP4_IPHDR_SZ)' "$BUILD/iput.c" | head -1 | cut -d: -f1)
s4=$(grep -n 'ptclcsum(bp, UDP4_PHDR_OFF' "$BUILD/iput.c" | head -1 | cut -d: -f1)
c6=$(grep -n 'udplenok(len, blocklen(bp) - UDP6_IPHDR_SZ)' "$BUILD/iput.c" | head -1 | cut -d: -f1)
s6=$(grep -n 'ptclcsum(bp, UDP6_PHDR_OFF' "$BUILD/iput.c" | head -1 | cut -d: -f1)
look=$(grep -n 'iphtlook(' "$BUILD/iput.c" | head -1 | cut -d: -f1)
if [ "$n" -eq 2 ] && [ -n "$s4" ] && [ -n "$s6" ] && [ -n "$look" ] &&
   [ "$c4" -lt "$s4" ] && [ "$c6" -lt "$s6" ] && [ "$c4" -lt "$look" ] && [ "$c6" -lt "$look" ]; then
	pass "the length is checked before the checksum runs over it and before a conversation is found or made"
else
	fail "udpiput uses a datagram's length before checking it (v4 check ${c4:-none} csum ${s4:-none}, v6 check ${c6:-none} csum ${s6:-none}, lookup ${look:-none})"
fi

# No way out of the input path keeps the block: every return is after a
# free, a trimblock that freed it, a padblock that did, or the queue.
leaks=$(awk '
	/freeblist\(bp\)|qpass\(c->rq, bp\)/ { freed = NR }
	/bp = trimblock\(|bp = padblock\(/ { gave = NR }
	/panic\(/ { dead = NR }
	/^[ \t]*return;/ {
		if(!(freed && NR - freed <= 3) && !(gave && NR - gave <= 12) && !(dead && NR - dead <= 1))
			print NR
	}
' "$BUILD/iput.c" | tr '\n' ' ')
if [ -z "$leaks" ] && ! grep -q 'goto Badlen' "$BUILD/iput.c"; then
	pass "every way out of udpiput has freed or queued the block"
else
	fail "udpiput returns holding its block (lines $leaks) or still jumps past trimblock"
fi

# The headers modes read the interface's address only when it has one.
if grep -q 'ucb->headers != 0 && ifc->lifc == nil' "$BUILD/iput.c" &&
   [ "$(grep -c 'ifc->lifc == nil' "$BUILD/iput.c")" -ge 2 ]; then
	pass "an interface with no address is not asked for one"
else
	fail "udpiput reads ifc->lifc->local without checking ifc->lifc"
fi

# udpadvise: the quoted packet is long enough for the version it claims.
awk '/^udpadvise\(/,/^}/' "$SRCFILE" > "$BUILD/advise.c"
a4=$(grep -n 'BLEN(bp) < UDP4_IPHDR_SZ + 4' "$BUILD/advise.c" | head -1 | cut -d: -f1)
r4=$(grep -n 'nhgets(h4->udpsport)' "$BUILD/advise.c" | head -1 | cut -d: -f1)
a6=$(grep -n 'BLEN(bp) < UDP6_IPHDR_SZ + 4' "$BUILD/advise.c" | head -1 | cut -d: -f1)
r6=$(grep -n 'nhgets(h6->udpsport)' "$BUILD/advise.c" | head -1 | cut -d: -f1)
if [ -n "$a4" ] && [ -n "$r4" ] && [ -n "$a6" ] && [ -n "$r6" ] && [ "$a4" -lt "$r4" ] && [ "$a6" -lt "$r6" ]; then
	pass "udpadvise reads a quoted packet's ports only when they arrived"
else
	fail "udpadvise reads past a short quoted packet (v4 check ${a4:-none}, v6 check ${a6:-none})"
fi

# Output: a write longer than the length field can say is not sent.
awk '/^udpkick\(/,/^}/' "$SRCFILE" > "$BUILD/kick.c"
k=$(grep -n 'dlen > 65535 - UDP_UDPHDR_SZ' "$BUILD/kick.c" | head -1 | cut -d: -f1)
u=$(grep -n 'ptcllen = dlen + UDP_UDPHDR_SZ' "$BUILD/kick.c" | head -1 | cut -d: -f1)
if [ -n "$k" ] && [ -n "$u" ] && [ "$k" -lt "$u" ]; then
	pass "a write too long for the 16-bit length is dropped, not sent as another length"
else
	fail "udpkick puts a length over 65535 in a 16-bit field"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
