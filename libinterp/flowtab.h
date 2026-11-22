/*
 * GENERATED from infernode-os/minos exp/flow/flow.h and flow.c, where
 * the table is tested on the host. Declarations, then the code: it is
 * included once, by flow.c. Not a .c file, because the bare-metal
 * harnesses compile every libinterp .c file there is.
 */
/*
 * The flow table: the whole of minos's per-packet work.
 * Plain C with no allocation and no libc beyond mem*: it is meant to
 * run in a kernel, behind a built-in module, or on the host for tests.
 *
 * A table is one block of memory: a Flowtab, then its entries. It
 * holds no pointers, so the block can be a Limbo array of byte: a
 * program that scribbles on it spoils its own table and nothing else.
 */
#ifndef FLOW_HAVE_TYPES		/* lib9.h has them already */
typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef unsigned long long uvlong;
#endif

enum {
	Fpass	= 1,
	Fdrop,
	Fdivert,
	Fcopy,

	/* flowkey's answers */
	Kok	= 0,
	Kshort	= -1,	/* the frame ends before what its headers promise */
	Knotip	= -2,	/* not IPv4 or IPv6 */
	Kfrag	= -3,	/* a later fragment: it has no ports */
	Kbad	= -4,	/* headers that contradict themselves */

	Ufree	= 0,
	Ulive,
	Uended,		/* idle too long: kept for flowsweep to report */

	Flook	= 16,	/* slots examined for a key: the bound on any lookup */
	Maxext	= 8,	/* IPv6 extension headers walked */
};

/*
 * Both directions of a flow have one key: a is the lesser of the two
 * (address, port) ends, b the greater. IPv4 addresses are v4-mapped.
 */
typedef struct Flowkey Flowkey;
struct Flowkey {
	uchar	a[16];
	uchar	b[16];
	ushort	ap;
	ushort	bp;
	uchar	proto;
	uchar	pad[3];
};

typedef struct Flowent Flowent;
struct Flowent {
	Flowkey	k;
	uchar	used;		/* Ufree, Ulive, Uended */
	uchar	verdict;
	uchar	first;		/* which end sent the first packet: 0 is a */
	uint	idle;		/* ms without a packet before it ends */
	uvlong	start;
	uvlong	last;
	uvlong	pkts[2];	/* [0] from a, [1] from b */
	uvlong	bytes[2];
};

typedef struct Flowtab Flowtab;
struct Flowtab {
	uint	n;		/* entries, a power of two; they follow this */
	uint	nent;		/* live */
	uvlong	k0, k1;		/* the hash's key: secret, random */
	uvlong	hits;
	uvlong	misses;
	uvlong	full;		/* adds refused: no slot among Flook */
	uvlong	ended;
	uvlong	lost;		/* ended entries reused before a sweep reported them */
};

int	flowkey(uchar *p, int n, Flowkey *k, int *dir);
uint	flowsize(uint n);
int	flowvalid(Flowtab *t, uvlong len);
void	flowinit(Flowtab *t, uint n, uvlong k0, uvlong k1);
Flowent*	flowlookup(Flowtab *t, Flowkey *k, int dir, int len, uvlong now);
Flowent*	flowadd(Flowtab *t, Flowkey *k, int dir, int verdict, uint idle, uvlong now);
int	flowsweep(Flowtab *t, uvlong now, Flowent *out, int max);


static uchar v4prefix[12] = { 0,0,0,0, 0,0,0,0, 0,0,0xff,0xff };

static uint
get16(uchar *p)
{
	return p[0]<<8 | p[1];
}

/*
 * The flow a frame belongs to. Nothing is read past p+n, and nothing
 * past what the IP header says the packet holds.
 */
int
flowkey(uchar *p, int n, Flowkey *k, int *dir)
{
	uchar src[16], dst[16];
	uint type, hl, tl, plen, nh, sp, dp, elen;
	int off, l4, end, i, c;

	if(n < 14)
		return Kshort;
	type = get16(p+12);
	off = 14;
	if(type == 0x8100){
		if(n < 18)
			return Kshort;
		type = get16(p+16);
		off = 18;
	}

	if(type == 0x0800){
		if(n < off+20)
			return Kshort;
		if((p[off]&0xF0) != 0x40)
			return Kbad;
		hl = (p[off]&0x0F)*4;
		if(hl < 20)
			return Kbad;
		tl = get16(p+off+2);
		if(tl < hl)
			return Kbad;
		if(off+(int)tl > n)
			return Kshort;
		end = off+tl;
		if(get16(p+off+6) & 0x1FFF)
			return Kfrag;
		nh = p[off+9];
		memcpy(src, v4prefix, 12);
		memcpy(src+12, p+off+12, 4);
		memcpy(dst, v4prefix, 12);
		memcpy(dst+12, p+off+16, 4);
		l4 = off+hl;
	}else if(type == 0x86DD){
		if(n < off+40)
			return Kshort;
		if((p[off]&0xF0) != 0x60)
			return Kbad;
		plen = get16(p+off+4);
		if(off+40+(int)plen > n)
			return Kshort;
		end = off+40+plen;
		nh = p[off+6];
		memcpy(src, p+off+8, 16);
		memcpy(dst, p+off+24, 16);
		l4 = off+40;
		for(i = 0; i < Maxext; i++){
			if(nh != 0 && nh != 43 && nh != 44 && nh != 51 && nh != 60)
				break;
			if(l4+8 > end)
				return Kshort;
			if(nh == 44){
				if(get16(p+l4+2) & 0xFFF8)
					return Kfrag;
				elen = 8;
			}else if(nh == 51)
				elen = (p[l4+1]+2)*4;
			else
				elen = (p[l4+1]+1)*8;
			nh = p[l4];
			if(l4+(int)elen > end)
				return Kshort;
			l4 += elen;
		}
		if(nh == 0 || nh == 43 || nh == 44 || nh == 51 || nh == 60)
			return Kbad;	/* more extension headers than anything honest sends */
	}else
		return Knotip;

	sp = dp = 0;
	switch(nh){
	case 6:
		if(l4+20 > end)
			return Kshort;
		sp = get16(p+l4);
		dp = get16(p+l4+2);
		break;
	case 17:
	case 132:
		if(l4+8 > end)
			return Kshort;
		sp = get16(p+l4);
		dp = get16(p+l4+2);
		break;
	}

	memset(k, 0, sizeof *k);
	k->proto = nh;
	c = memcmp(src, dst, 16);
	if(c < 0 || (c == 0 && sp <= dp)){
		memcpy(k->a, src, 16);
		memcpy(k->b, dst, 16);
		k->ap = sp;
		k->bp = dp;
		*dir = 0;
	}else{
		memcpy(k->a, dst, 16);
		memcpy(k->b, src, 16);
		k->ap = dp;
		k->bp = sp;
		*dir = 1;
	}
	return Kok;
}

/*
 * SipHash-2-4 (Aumasson and Bernstein). Keyed, so that whoever sends
 * the packets cannot choose which slots their flows land in.
 */
#define ROTL(x, b) (((x)<<(b)) | ((x)>>(64-(b))))
#define ROUND \
	v0 += v1; v1 = ROTL(v1, 13); v1 ^= v0; v0 = ROTL(v0, 32); \
	v2 += v3; v3 = ROTL(v3, 16); v3 ^= v2; \
	v0 += v3; v3 = ROTL(v3, 21); v3 ^= v0; \
	v2 += v1; v1 = ROTL(v1, 17); v1 ^= v2; v2 = ROTL(v2, 32)

static uvlong
le64(uchar *p)
{
	uvlong v;
	int i;

	v = 0;
	for(i = 7; i >= 0; i--)
		v = v<<8 | p[i];
	return v;
}

uvlong
flowhash(uvlong k0, uvlong k1, uchar *p, int n)
{
	uvlong v0, v1, v2, v3, m;
	int i, left;

	v0 = k0 ^ 0x736f6d6570736575ULL;
	v1 = k1 ^ 0x646f72616e646f6dULL;
	v2 = k0 ^ 0x6c7967656e657261ULL;
	v3 = k1 ^ 0x7465646279746573ULL;
	for(i = 0; i+8 <= n; i += 8){
		m = le64(p+i);
		v3 ^= m;
		ROUND; ROUND;
		v0 ^= m;
	}
	left = n-i;
	m = (uvlong)n << 56;
	while(--left >= 0)
		m |= (uvlong)p[i+left] << (8*left);
	v3 ^= m;
	ROUND; ROUND;
	v0 ^= m;
	v2 ^= 0xff;
	ROUND; ROUND; ROUND; ROUND;
	return v0 ^ v1 ^ v2 ^ v3;
}

#define ENTS(t)	((Flowent*)((t)+1))

uint
flowsize(uint n)
{
	return sizeof(Flowtab) + n*sizeof(Flowent);
}

/* is t, in len bytes, a table? Asked before every use of memory a program owns. */
int
flowvalid(Flowtab *t, uvlong len)
{
	if(len < sizeof(Flowtab) || t->n < Flook || (t->n & (t->n-1)) != 0)
		return 0;
	return (len - sizeof(Flowtab)) / sizeof(Flowent) >= t->n;
}

void
flowinit(Flowtab *t, uint n, uvlong k0, uvlong k1)
{
	memset(t, 0, flowsize(n));
	t->n = n;
	t->k0 = k0;
	t->k1 = k1;
}

/*
 * A clock that has gone back (stepped, or one caller's a little
 * behind another's) ends nothing: the difference is unsigned, and an
 * earlier now would be an enormous idle time.
 */
static int
expired(Flowent *e, uvlong now)
{
	return now > e->last && now - e->last > e->idle;
}

static void
endent(Flowtab *t, Flowent *e)
{
	e->used = Uended;
	t->nent--;
	t->ended++;
}

static Flowent*
find(Flowtab *t, Flowkey *k, uint h, uvlong now)
{
	Flowent *e;
	int i;

	for(i = 0; i < Flook; i++){
		e = &ENTS(t)[(h+i) & (t->n-1)];
		if(e->used == Ulive && memcmp(&e->k, k, sizeof *k) == 0){
			if(expired(e, now)){
				endent(t, e);
				return 0;
			}
			return e;
		}
	}
	return 0;
}

Flowent*
flowlookup(Flowtab *t, Flowkey *k, int dir, int len, uvlong now)
{
	Flowent *e;

	e = find(t, k, flowhash(t->k0, t->k1, (uchar*)k, sizeof *k), now);
	if(e == 0){
		t->misses++;
		return 0;
	}
	e->last = now;
	e->pkts[dir]++;
	e->bytes[dir] += len;
	t->hits++;
	return e;
}

/*
 * A verdict for a flow. Refused (nil) when none of the key's Flook
 * slots can be had: the table is a fixed size and a flood does not
 * make it larger. A free slot is taken first, then one whose flow
 * has ended; its record is lost if no sweep has reported it.
 */
Flowent*
flowadd(Flowtab *t, Flowkey *k, int dir, int verdict, uint idle, uvlong now)
{
	Flowent *e, *slot;
	uint h;
	int i;

	h = flowhash(t->k0, t->k1, (uchar*)k, sizeof *k);
	e = find(t, k, h, now);
	if(e != 0){
		e->verdict = verdict;
		e->idle = idle;
		return e;
	}
	slot = 0;
	for(i = 0; i < Flook && slot == 0; i++){
		e = &ENTS(t)[(h+i) & (t->n-1)];
		if(e->used == Ufree)
			slot = e;
	}
	for(i = 0; i < Flook && slot == 0; i++){
		e = &ENTS(t)[(h+i) & (t->n-1)];
		if(e->used == Ulive && expired(e, now))
			endent(t, e);
		if(e->used == Uended){
			t->lost++;
			slot = e;
		}
	}
	if(slot == 0){
		t->full++;
		return 0;
	}
	memset(slot, 0, sizeof *slot);
	slot->k = *k;
	slot->used = Ulive;
	slot->verdict = verdict;
	slot->first = dir;
	slot->idle = idle;
	slot->start = now;
	slot->last = now;
	t->nent++;
	return slot;
}

/*
 * Copy out, and free, up to max entries whose flows have ended:
 * the flow records. Returns how many; call again if it returns max.
 */
int
flowsweep(Flowtab *t, uvlong now, Flowent *out, int max)
{
	Flowent *e;
	uint i;
	int n;

	n = 0;
	for(i = 0; i < t->n && n < max; i++){
		e = &ENTS(t)[i];
		if(e->used == Ulive && expired(e, now))
			endent(t, e);
		if(e->used == Uended){
			out[n++] = *e;
			e->used = Ufree;
		}
	}
	return n;
}
