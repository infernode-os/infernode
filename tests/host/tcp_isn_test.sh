#!/bin/sh
# TCP (os/ip/tcp.c): where a connection's first sequence number comes
# from, how small a peer may make our segments, and which reset closes
# a connection.
#
# isnkey, tcpisn, peermss and rstexact are extracted from the source
# and run. Initial sequence numbers (RFC 6528): the key is what the
# hardware generator gives, taken in whatever pieces it gives them and
# never waited for, and made up when there is none; the number is a
# keyed hash of both addresses and both ports plus a clock, so two
# connections' numbers differ in every one of 4000 pairs of ends, one
# pair of ends used again is ahead of where it was, and another key
# gives other numbers. A peer's MSS option is taken down to Minmss and
# no further, and never above ours. Only a reset at exactly the next
# sequence number expected is one. By the order of the source: no
# sequence number is drawn from nrand; a reset elsewhere in the window
# is answered and the connection kept; a header longer than its packet
# frees the packet; the resequence queue's limit is not printed for
# every packet that reaches it.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/tcp.c
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

awk '/^static struct \{$/,/^\} isn;/' "$SRCFILE" > "$BUILD/fns.inc"
{ echo 'static void'; awk '/^isnkey\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static u32int'; awk '/^tcpisn\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static int'; awk '/^peermss\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static int'; awk '/^rstexact\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
MINMSS=$(sed -n 's/^[ \t]*Minmss[ \t]*=[ \t]*\([0-9]*\),.*/\1/p' "$SRCFILE" | head -1)
for fn in isnkey tcpisn peermss rstexact; do
	if ! grep -q "^$fn(" "$BUILD/fns.inc"; then
		fail "tcp.c has no $fn to run"
		echo "Passed: $PASSED  Failed: $FAILED"
		exit 1
	fi
done
if [ -z "$MINMSS" ] || ! grep -q '} isn;' "$BUILD/fns.inc"; then
	fail "tcp.c has no Minmss or no key for its sequence numbers"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<EOT
#include <stdio.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int u32int;
typedef unsigned long ulong;
typedef unsigned long long uvlong;
#define nil ((void*)0)
enum { IPaddrlen = 16, SHA256dlen = 32, Minmss = $MINMSS };
typedef struct Lock Lock;
struct Lock { int held; };
static void lock(Lock *l){ l->held++; }
static void unlock(Lock *l){ l->held--; }

/* a hardware generator that is scripted: none, or so many bytes a call */
static int hwmode;	/* -1 none; n > 0: at most n bytes a call, then dry after hwleft */
static int hwleft;
static int hwcalls;
static uchar hwnext = 0x80;
static int
hwrandom(uchar *p, int n)
{
	int i;
	hwcalls++;
	if(hwmode < 0)
		return -1;
	if(n > hwmode)
		n = hwmode;
	if(n > hwleft)
		n = hwleft;
	for(i = 0; i < n; i++)
		p[i] = hwnext++;
	hwleft -= n;
	return n;
}
static int nrandcalls;
static int nrand(int n){ nrandcalls++; return (nrandcalls * 37 + 11) % n; }
static uvlong clockns = 1000000;
static uvlong fastticks(uvlong *hz){ (void)hz; return clockns; }
static uvlong fastticks2ns(uvlong t){ return t; }

/* not HMAC: any function of all of the key and all of the message will show what tcpisn gives it */
static uchar lastkey[64], lastmsg[64];
static int lastklen, lastmlen;
static void*
hmac_sha256(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, void *s)
{
	uvlong h = 1469598103934665603ULL;
	ulong i;
	(void)s;
	memcpy(lastkey, key, klen); lastklen = klen;
	memcpy(lastmsg, p, len); lastmlen = len;
	for(i = 0; i < klen; i++){ h ^= key[i]; h *= 1099511628211ULL; }
	for(i = 0; i < len; i++){ h ^= p[i]; h *= 1099511628211ULL; }
	for(i = 0; i < SHA256dlen; i++){ digest[i] = h >> 56; h *= 6364136223846793005ULL; h += 1442695040888963407ULL; }
	return nil;
}

#include "fns.inc"

static int bad;
static void
check(int cond, const char *what)
{
	if(!cond){
		printf("  %s\n", what);
		bad++;
	}
}

static void
rekey(int mode, int left)
{
	memset(&isn, 0, sizeof isn);
	hwmode = mode;
	hwleft = left;
	hwcalls = nrandcalls = 0;
}

int
main(void)
{
	uchar la[IPaddrlen], ra[IPaddrlen], k1[32];
	static u32int seen[4000];
	u32int a, b, c;
	int i, j, dup, n;

	memset(la, 0, sizeof la); la[10] = la[11] = 0xff; la[12] = 10; la[15] = 15;
	memset(ra, 0, sizeof ra); ra[10] = ra[11] = 0xff; ra[12] = 10; ra[15] = 2;

	/* the key: all of it from the generator when it gives enough, in pieces */
	rekey(5, 1000);
	a = tcpisn(la, 564, ra, 40000);
	check(isn.set == 1 && isn.lk.held == 0, "the key is set once, and its lock let go");
	check(nrandcalls == 0, "with a generator, nothing of the key is made up");
	check(hwcalls >= 7 && hwcalls <= 8, "the generator is asked again for what it did not give, a few times");
	check(lastklen == 32 && lastmlen == 2*IPaddrlen + 4, "the hash is over a 32-byte key and both ends");
	check(memcmp(lastmsg, la, 16) == 0 && memcmp(lastmsg+16, ra, 16) == 0, "both addresses are hashed");
	check(lastmsg[32] == (564>>8) && lastmsg[33] == (564&0xff) && lastmsg[34] == (40000>>8) && lastmsg[35] == (40000&0xff), "and both ports");
	memcpy(k1, isn.key, 32);
	n = 0;
	for(i = 0; i < 24; i++)
		if(k1[i] == (uchar)(0x80 + i))
			n++;
	check(n == 24, "the key is the generator's bytes");

	/* the same ends a moment later: ahead by the clock, and by nothing else */
	clockns += 4000 * 1000;
	b = tcpisn(la, 564, ra, 40000);
	check(b - a == 1000, "the same ends 4 ms later are 1000 ahead");
	check(hwcalls <= 8, "the key is not made again");

	/* other ends: other numbers, in every pair */
	dup = 0;
	n = 0;
	for(i = 0; i < 4000; i++){
		seen[i] = tcpisn(la, 564, ra, 1024 + i);
		for(j = 0; j < i; j++)
			if(seen[j] == seen[i])
				dup++;
		if(i > 0 && seen[i] - seen[i-1] < 65536)
			n++;
	}
	check(dup == 0, "4000 remote ports gave some sequence number twice");
	check(n < 40, "sequence numbers for neighbouring ports are near one another");
	c = tcpisn(la, 565, ra, 40000);
	check(c != b, "another local port gives another number");
	ra[15] = 3;
	check(tcpisn(la, 564, ra, 40000) != b, "another remote address gives another number");
	ra[15] = 2;

	/* another key: other numbers for the same ends at the same time */
	hwnext = 0x10;
	rekey(32, 1000);
	check(tcpisn(la, 564, ra, 40000) != b, "another key gives the same number for the same ends");
	check(hwcalls == 1, "a generator that gives all it is asked for is asked once");

	/* a generator that runs dry part way, and none at all: no wait, and a key all the same */
	rekey(4, 10);
	tcpisn(la, 564, ra, 40000);
	check(isn.set == 1 && hwcalls <= 8 && nrandcalls == 22, "a generator that gives 10 bytes and stops leaves 22 to be made up, and is not waited for");
	rekey(-1, 0);
	tcpisn(la, 564, ra, 40000);
	check(isn.set == 1 && hwcalls == 1 && nrandcalls == 32, "with no generator the key is made up, at once");

	/* the peer's MSS */
	check(peermss(0, 1460) == 1460, "no MSS option leaves ours");
	check(peermss(1460, 1460) == 1460 && peermss(9000, 1460) == 1460, "an MSS at or above ours leaves ours");
	check(peermss(536, 1460) == 536, "a smaller MSS is taken");
	check(peermss(Minmss, 1460) == Minmss, "down to the least");
	check(peermss(Minmss - 1, 1460) == Minmss && peermss(1, 1460) == Minmss, "and no further");
	check(peermss(1, 100) == 100 && peermss(50, 100) == 100, "but never above ours, when ours is under the least");
	for(i = 0; i < 65536; i++){
		n = peermss(i, 1460);
		if(n > 1460 || n < Minmss){
			check(0, "an MSS option made our segments larger than ours or smaller than the least");
			break;
		}
	}

	/* which reset is one */
	check(rstexact(1000, 1000) == 1, "a reset at the next sequence number expected is one");
	check(rstexact(1001, 1000) == 0 && rstexact(999, 1000) == 0 && rstexact(1000 + 65535, 1000) == 0, "a reset anywhere else is not");
	check(rstexact(0, 0xffffffffU) == 0 && rstexact(0xffffffffU, 0xffffffffU) == 1, "at the end of the sequence space too");
	return bad != 0;
}
EOT

SAN=
if echo 'int main(void){return 0;}' > "$BUILD/san.c" &&
   "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null &&
   "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
if "$CC" -std=gnu99 -Wall -Wno-unused-function -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "sequence numbers are a keyed hash of the connection's ends plus a clock; a peer's MSS has a floor; a reset is exact${SAN:+ (ASan, UBSan)}"
	else
		fail "tcp: $(head -8 "$BUILD/run.out" | tr '\n' ' ' | cut -c1-600)"
	fi
else
	fail "test did not compile: $(head -5 "$BUILD/cc.err" | tr '\n' ' ' | cut -c1-400)"
fi

# No sequence number is drawn from nrand.
if grep -q 'tcb->iss = tcpisn(s->laddr, s->lport, s->raddr, s->rport)' "$SRCFILE" &&
   grep -q 'lp->iss = tcpisn(dest, seg->dest, source, seg->source)' "$SRCFILE" &&
   ! grep -q 'iss = (nrand' "$SRCFILE"; then
	pass "both the connecting and the listening side take their first sequence number from tcpisn"
else
	fail "an initial sequence number is still drawn from nrand"
fi

# The peer's MSS is taken only through peermss.
if [ "$(grep -c 'tcb->mss = peermss(' "$SRCFILE")" -eq 2 ] && ! grep -q 'tcb->mss = seg->mss\|tcb->mss = lp->mss' "$SRCFILE"; then
	pass "a peer's MSS option reaches our segment size only through its floor"
else
	fail "a peer's MSS option is taken as it comes"
fi

# A reset elsewhere in the window is answered, the connection kept.
awk '/^tcpiput\(/,/^}/' "$SRCFILE" > "$BUILD/iput.c"
ck=$(grep -n 'if(!rstexact(seg.seq, tcb->rcv.nxt)){' "$BUILD/iput.c" | head -1 | cut -d: -f1)
cl=$(awk -v s="${ck:-0}" 'NR > s && /localclose\(s, Econrefused\)/ { print NR; exit }' "$BUILD/iput.c")
if [ -n "$ck" ] && [ -n "$cl" ] &&
   awk -v a="$ck" -v b="$cl" 'NR > a && NR < b' "$BUILD/iput.c" | grep -q 'goto output' &&
   awk -v a="$ck" -v b="$cl" 'NR > a && NR < b' "$BUILD/iput.c" | grep -q 'tcb->flags |= FORCE' &&
   ! grep -q 'print("out of order RST' "$BUILD/iput.c"; then
	pass "a reset not at the next sequence number is answered with an ACK and closes nothing"
else
	fail "tcpiput closes a connection on a reset anywhere in the window"
fi

# A header longer than its packet frees the packet; nothing a peer drives prints each time.
n=$(grep -c 'if(hdrlen >= 0)' "$BUILD/iput.c")
if [ "$n" -eq 2 ] && ! grep -q 'print("reseq ' "$BUILD/iput.c" &&
   awk '/^addreseq\(/,/^}/' "$SRCFILE" | grep -q 'reseqsaid'; then
	pass "a header longer than its packet frees it, and the resequence queue's limit is reported once a minute at most"
else
	fail "tcpiput keeps a packet whose header is longer than it, or prints for every packet a peer sends"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
