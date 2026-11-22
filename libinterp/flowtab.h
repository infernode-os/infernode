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
