#!/bin/sh
# IPv6 reassembly (os/ip/ipv6.c), run for real: unfraglen,
# ip6reassemble and the queue functions are extracted from the source
# and driven with fragments in Blocks exactly as long as their data,
# under ASan and UBSan, so a byte written or read outside a fragment
# is a report.
#
# What must hold: fragments in either order make the datagram; two
# fragments whose headers before the fragment header differ in length
# (one plain, one behind 1400 bytes of hop-by-hop options) are put
# together by each one's own length, writing nothing outside either;
# fragments that overlap abandon the datagram, an exact duplicate is
# dropped alone; a fragment with no data, or not a multiple of eight
# bytes with more to come, or ending past 65535, is no fragment; data
# after the fragment that says it is last abandons the datagram; a
# datagram is held in at most Maxfrags6 pieces; a queue that has
# waited too long goes when the next fragment of anything arrives; a
# packet with a fragment header that is the whole datagram comes back
# without it; a fragment that arrives as a chain, or with no room
# before it, is taken the same.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/ipv6.c
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

awk '/^struct Fragment6$/,/^};/' "$SRCFILE" > "$BUILD/types.inc"
awk '/^struct Ipfrag$/,/^};/' "$SRCFILE" >> "$BUILD/types.inc"
awk '/^enum \{$/,/^};/' "$SRCFILE" | awk '/Maxfrags6/ { found = 1 } { buf = buf $0 "\n" } /^};/ { if(found) printf "%s", buf; buf = ""; found = 0 }' >> "$BUILD/types.inc"
: > "$BUILD/fns.inc"
for fn in fragfits fragok; do
	{ echo 'static int'; awk "/^$fn\\(/,/^}/" "$SRCFILE"; } >> "$BUILD/fns.inc"
done
{ echo 'static int'; awk '/^unfraglen\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static void'; awk '/^ipfragfree6\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static Fragment6*'; awk '/^ipfragallo6\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
{ echo 'static Block*'; awk '/^ip6reassemble\(/,/^}/' "$SRCFILE"; } >> "$BUILD/fns.inc"
for fn in fragfits fragok unfraglen ipfragfree6 ipfragallo6 ip6reassemble; do
	if ! grep -q "^$fn(" "$BUILD/fns.inc"; then
		fail "ipv6.c has no $fn to run"
		echo "Passed: $PASSED  Failed: $FAILED"
		exit 1
	fi
done
if ! grep -q Maxfrags6 "$BUILD/types.inc"; then
	fail "ipv6.c sets no limit on the fragments of one datagram"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef unsigned long ulong;
#define nil ((void*)0)

typedef struct Block Block;
struct Block { Block *next; uchar *rp, *wp, *lim, *base; };
#define BLEN(b)	((b)->wp - (b)->rp)
#define BKFG(xp)	((Ipfrag*)((xp)->base))

typedef struct QLock QLock;
struct QLock { int held; };
static void qlock(QLock *q){ if(q->held){ printf("  lock taken twice\n"); exit(1); } q->held = 1; }
static void qunlock(QLock *q){ if(!q->held){ printf("  lock released unheld\n"); exit(1); } q->held = 0; }

enum { IPaddrlen = 16, IP6HDR = 40, IP6FHDR = 8, HBH = 0, RH = 43, FH = 44 };
enum { ReasmTimeout, ReasmReqds, ReasmOKs, ReasmFails, Nstats };

typedef struct Ip6hdr Ip6hdr;
struct Ip6hdr { uchar vcf[4]; uchar ploadlen[2]; uchar proto; uchar ttl; uchar src[IPaddrlen]; uchar dst[IPaddrlen]; };
typedef struct Fraghdr6 Fraghdr6;
struct Fraghdr6 { uchar nexthdr; uchar res; uchar offsetRM[2]; uchar id[4]; };

typedef struct Fragment6 Fragment6;
typedef struct Ipfrag Ipfrag;
#include "types.inc"

typedef struct IP IP;
struct IP { ulong stats[Nstats]; QLock fraglock6; Fragment6 *flisthead6; Fragment6 *fragfree6; };

static ulong now = 1000;
#define NOW now

static int nblocks;	/* live Blocks: none may be left, or freed twice */

static Block*
allocb(int size)
{
	Block *b = malloc(sizeof *b);
	b->base = malloc(size > 0 ? size : 1);	/* exactly: nothing spare to write into unseen */
	b->rp = b->wp = b->base;
	b->lim = b->base + size;
	b->next = nil;
	nblocks++;
	return b;
}
static void freeb(Block *b){ if(b == nil) return; free(b->base); free(b); nblocks--; }
static void freeblist(Block *b){ Block *n; for(; b != nil; b = n){ n = b->next; freeb(b); } }
static int blocklen(Block *b){ int n = 0; for(; b != nil; b = b->next) n += BLEN(b); return n; }
static Block*
pullupblock(Block *bp, int n)
{
	Block *nb, *b;
	(void)n;
	nb = allocb(blocklen(bp));
	for(b = bp; b != nil; b = b->next){
		memmove(nb->wp, b->rp, BLEN(b));
		nb->wp += BLEN(b);
	}
	freeblist(bp);
	return nb;
}
static Block*
padblock(Block *bp, int size)
{
	Block *nbp;
	int n;
	if(bp->rp - bp->base >= size){
		bp->rp -= size;
		return bp;
	}
	n = BLEN(bp);
	nbp = allocb(size + n);
	nbp->rp += size;
	nbp->wp = nbp->rp;
	memmove(nbp->wp, bp->rp, n);
	nbp->wp += n;
	freeb(bp);
	nbp->rp -= size;
	return nbp;
}
static ushort nhgets(uchar *p){ return p[0]<<8 | p[1]; }
static uint nhgetl(uchar *p){ return (uint)p[0]<<24 | p[1]<<16 | p[2]<<8 | p[3]; }
static void hnputs(uchar *p, int v){ p[0] = v>>8; p[1] = v; }
static int ipcmp(uchar *a, uchar *b){ return memcmp(a, b, IPaddrlen); }

#include "fns.inc"

static IP ip;
static Fragment6 pool[4];
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
reset(void)
{
	int i;
	while(ip.flisthead6 != nil)
		ipfragfree6(&ip, ip.flisthead6);
	memset(&ip, 0, sizeof ip);
	memset(pool, 0, sizeof pool);
	for(i = 0; i < 4; i++){
		pool[i].next = ip.fragfree6;
		ip.fragfree6 = &pool[i];
	}
	now = 1000;
}

/*
 * A fragment: 40-byte header, ext bytes of hop-by-hop options (a
 * multiple of 8, or 0), a fragment header, n bytes of data that are
 * fill, fill+1, ...; room bytes free before it, as a driver leaves.
 */
static Block*
frag(uint id, int off, int more, int ext, int n, int fill, int room)
{
	Block *b = allocb(room + IP6HDR + ext + IP6FHDR + n);
	uchar *p;
	int i;

	b->rp += room;
	p = b->rp;
	memset(p, 0, IP6HDR + ext + IP6FHDR);
	p[0] = 0x60;
	hnputs(p+4, ext + IP6FHDR + n);
	p[6] = ext ? HBH : FH;
	p[7] = 64;
	p[8] = 0xfe; p[9] = 0x80; p[23] = 1;
	p[24] = 0xfe; p[25] = 0x80; p[39] = 2;
	p += IP6HDR;
	if(ext){
		p[0] = FH;
		p[1] = ext/8 - 1;
		p += ext;
	}
	p[0] = 17;
	hnputs(p+2, off | more);
	p[4] = id>>24; p[5] = id>>16; p[6] = id>>8; p[7] = id;
	p += IP6FHDR;
	for(i = 0; i < n; i++)
		p[i] = fill + i;
	b->wp = p + n;
	return b;
}

/* as procxtns does it */
static Block*
input(Block *b)
{
	uchar proto;
	int ufl;

	ufl = unfraglen(b, &proto, 0);
	if(ufl < 0){
		freeblist(b);
		return nil;
	}
	if(proto != FH)
		return b;
	return ip6reassemble(&ip, ufl, b, (Ip6hdr*)b->rp);
}

/* the datagram as one run of bytes, into buf; its length */
static int
flat(Block *b, uchar *buf, int max)
{
	int n = 0;
	for(; b != nil; b = b->next){
		if(n + BLEN(b) > max)
			return -1;
		memmove(buf + n, b->rp, BLEN(b));
		n += BLEN(b);
	}
	return n;
}

static int
queued(void)
{
	Fragment6 *f;
	Block *b;
	int n = 0;
	for(f = ip.flisthead6; f != nil; f = f->next)
		for(b = f->blist; b != nil; b = b->next)
			n++;
	return n;
}

static uchar buf[70000];

static void
whole(Block *r, int ext, int n, const char *what)
{
	int len, i, ok;
	char msg[200];

	snprintf(msg, sizeof msg, "%s: no datagram", what);
	check(r != nil, msg);
	if(r == nil)
		return;
	len = flat(r, buf, sizeof buf);
	ok = len == IP6HDR + ext + n && nhgets(buf+4) == ext + n;
	if(ok && ext)
		ok = buf[6] == HBH && buf[IP6HDR] == 17;
	else if(ok)
		ok = buf[6] == 17;
	for(i = 0; ok && i < n; i++)
		ok = buf[IP6HDR + ext + i] == (uchar)i;
	snprintf(msg, sizeof msg, "%s: the datagram is not its fragments' data in order (%d bytes, payload length %d)", what, len, nhgets(buf+4));
	check(ok, msg);
	freeblist(r);
}

int
main(void)
{
	Block *r, *a, *b;
	int i, room;

	for(room = 0; room <= 14; room += 14){
		/* in order, and out of order */
		reset();
		r = input(frag(7, 0, 1, 0, 16, 0, room));
		check(r == nil && queued() == 1, "a first fragment is held");
		whole(input(frag(7, 16, 0, 0, 8, 16, room)), 0, 24, "in order");
		check(queued() == 0 && ip.stats[ReasmOKs] == 1, "and the queue is given back");

		reset();
		input(frag(7, 16, 0, 0, 8, 16, room));
		whole(input(frag(7, 0, 1, 0, 16, 0, room)), 0, 24, "out of order");

		reset();
		input(frag(7, 8, 1, 0, 8, 8, room));
		input(frag(7, 16, 0, 0, 5, 16, room));
		whole(input(frag(7, 0, 1, 0, 8, 0, room)), 0, 21, "three, the first last");

		/* headers of different lengths before the fragment header */
		reset();
		input(frag(9, 0, 1, 0, 8, 0, room));
		whole(input(frag(9, 8, 0, 1400, 8, 8, room)), 0, 16, "a short first fragment and a long-headed second");
		reset();
		input(frag(9, 8, 0, 0, 8, 8, room));
		whole(input(frag(9, 0, 1, 1400, 8, 0, room)), 1400, 16, "a long-headed first fragment and a short second");
		reset();
		input(frag(9, 0, 1, 16, 8, 0, room));
		input(frag(9, 16, 0, 1400, 8, 16, room));
		whole(input(frag(9, 8, 1, 0, 8, 8, room)), 16, 24, "three fragments with three header lengths");

		/* overlap: the datagram is abandoned */
		reset();
		input(frag(3, 0, 1, 0, 16, 0, room));
		r = input(frag(3, 8, 0, 0, 16, 8, room));
		check(r == nil && queued() == 0 && ip.stats[ReasmFails] == 1, "a fragment overlapping the one before abandons the datagram");
		reset();
		input(frag(3, 16, 0, 0, 8, 16, room));
		r = input(frag(3, 8, 1, 0, 16, 8, room));
		check(r == nil && queued() == 0 && ip.stats[ReasmFails] == 1, "a fragment overlapping the one after abandons the datagram");
		reset();
		input(frag(3, 0, 1, 0, 24, 0, room));
		r = input(frag(3, 8, 1, 0, 8, 8, room));
		check(r == nil && queued() == 0, "a fragment inside another abandons the datagram");

		/* an exact duplicate is dropped alone */
		reset();
		input(frag(4, 0, 1, 0, 16, 0, room));
		r = input(frag(4, 0, 1, 0, 16, 0, room));
		check(r == nil && queued() == 1 && ip.stats[ReasmFails] == 0, "a fragment delivered twice is kept once");
		whole(input(frag(4, 16, 0, 0, 8, 16, room)), 0, 24, "after a duplicate");

		/* what is no fragment */
		reset();
		r = input(frag(5, 0, 1, 0, 0, 0, room));
		check(r == nil && queued() == 0, "a fragment with no data is not queued");
		r = input(frag(5, 0, 1, 0, 13, 0, room));
		check(r == nil && queued() == 0, "a fragment of 13 bytes with more to come is not queued");
		r = input(frag(5, 65528, 0, 0, 16, 0, room));
		check(r == nil && queued() == 0, "a fragment ending past 65535 is not queued");
		reset();
		input(frag(5, 0, 1, 0, 8, 0, room));
		r = input(frag(5, 65528, 0, 0, 16, 0, room));
		check(r == nil && queued() == 0, "and takes what was queued for its datagram with it");

		/* data after the last fragment */
		reset();
		input(frag(6, 8, 0, 0, 8, 8, room));
		input(frag(6, 16, 1, 0, 8, 16, room));
		r = input(frag(6, 0, 1, 0, 8, 0, room));
		check(r == nil && queued() == 0, "data after the fragment that is last abandons the datagram");

		/* the whole datagram in one fragment header's packet */
		reset();
		r = input(frag(8, 0, 0, 0, 20, 0, room));
		whole(r, 0, 20, "a packet with a fragment header that is the whole datagram");
		reset();
		r = input(frag(8, 0, 0, 24, 20, 0, room));
		whole(r, 24, 20, "the same behind an extension header");
		reset();
		input(frag(8, 0, 1, 0, 8, 0, room));
		r = input(frag(8, 0, 0, 0, 20, 0, room));
		whole(r, 0, 20, "and it supersedes fragments held under its id");
		check(queued() == 0, "which are let go");

		/* never more pieces than a datagram needs */
		reset();
		for(i = 0; i < 200; i++){
			r = input(frag(11, 8*i, 1, 0, 8, 0, room));
			check(r == nil, "an unfinished datagram yields nothing");
			check(queued() <= Maxfrags6, "a datagram is held in more pieces than the limit");
		}
		check(queued() < Maxfrags6, "the datagram was not abandoned at the limit");

		/* a queue that has waited too long */
		reset();
		input(frag(12, 0, 1, 0, 8, 0, room));
		now += 40000;
		input(frag(13, 0, 1, 0, 8, 0, room));
		check(queued() == 1 && ip.stats[ReasmTimeout] == 1, "an old queue goes when another datagram's fragment arrives");
		now += 40000;
		r = input(frag(13, 8, 0, 0, 8, 8, room));
		check(r == nil && ip.stats[ReasmTimeout] == 2, "and a fragment does not complete a datagram that has timed out");

		/* a fragment in two Blocks */
		reset();
		input(frag(14, 0, 1, 0, 16, 0, room));
		a = frag(14, 16, 0, 0, 8, 16, room);
		b = allocb(4);		/* the headers in the first Block, as ipiput6 leaves them */
		memmove(b->wp, a->wp - 4, 4);
		b->wp += 4;
		a->wp -= 4;
		a->next = b;
		whole(input(a), 0, 24, "a fragment that arrives as a chain");
	}
	reset();
	check(nblocks == 0, "Blocks were lost or freed twice");
	if(nblocks != 0)
		printf("  (%d outstanding)\n", nblocks);
	return bad != 0;
}
EOT

SAN=
if echo 'int main(void){return 0;}' > "$BUILD/san.c" &&
   "$CC" -fsanitize=address,undefined -o "$BUILD/san" "$BUILD/san.c" 2>/dev/null &&
   "$BUILD/san" 2>/dev/null; then
	SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
fi
if "$CC" -std=gnu99 -Wall -Wno-unused-function -Wno-unused-label -Wno-parentheses -g $SAN -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err"; then
	if "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "fragments are put together by their own lengths, and what is no part of a datagram is let go${SAN:+ (ASan, UBSan)}"
	else
		fail "reassembly: $(head -8 "$BUILD/run.out" | tr '\n' ' ' | cut -c1-600)"
	fi
else
	fail "test did not compile: $(head -6 "$BUILD/cc.err" | tr '\n' ' ' | cut -c1-500)"
fi

# A packet passed on with its fragment header still says one comes next.
awk '/^procxtns\(/,/^}/' "$SRCFILE" > "$BUILD/px.c"
if grep -q 'if(proto == FH && doreasm == 0){' "$BUILD/px.c" && grep -q 'unfraglen(bp, &proto, 1)' "$BUILD/px.c"; then
	pass "a fragment that is forwarded keeps its fragment header named"
else
	fail "procxtns leaves a forwarded fragment naming its payload where its fragment header is"
fi

# The not-for-me drop frees the whole chain, and a tentative address is logged, not printed.
awk '/^ipiput6\(/,/^}/' "$SRCFILE" > "$BUILD/iput.c"
if ! grep -q 'freeb(bp)' "$BUILD/iput.c" && ! grep -q 'print("tentative' "$BUILD/iput.c"; then
	pass "ipiput6 frees whole chains and prints nothing per packet"
else
	fail "ipiput6 frees only the first Block of a packet it drops, or prints on the console for each"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
