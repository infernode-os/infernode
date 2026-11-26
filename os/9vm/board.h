/*
 * os/9vm -- the 9vm board: its #~ host ring and the 9P above it.
 *
 * 9vm (https://github.com/kiljoy001/9vm) reserves the top 2 MiB of guest
 * physical RAM, publishes it in the Multiboot map as a private entry of
 * type 0x9009, and serves 9P2000 from a host thread on the other side.
 * The region is a duplex pair of submission/completion rings and eight
 * pairs of 32 KiB request and response buffers.  A descriptor names a
 * buffer by index, never by address.
 *
 * The layout below is the guest's copy of 9vm's 9ring.h.  That file is
 * the authority; ring.c asserts the sizes and offsets at compile time so
 * a change on the host side fails the build here rather than corrupting
 * memory on the ring.
 *
 * There are two channels.  The first is the host filesystem.  The second
 * is the ns channel, the guest's #~/ns, which 9vm relays to whatever 9P
 * server it was given with -ns; the host advertises it in features and
 * it is absent otherwise.
 */

#ifndef _OS_9VM_BOARD_H_
#define _OS_9VM_BOARD_H_

#include <stdint.h>
#include "../amd64/console.h"

/* The ring's message size and slot count. */
#define P9_RING_SIZE		256
#define P9_RING_MASK		(P9_RING_SIZE - 1)
#define P9_CACHELINE		64

#define P9_HOST_MAGIC		0x39524853U
#define P9_HOST_VERSION		1
#define P9_HOST_SLOTS		8
#define P9_HOST_MSIZE		32768
#define P9_HOST_REGION_SIZE	(2 * 1024 * 1024)
#define P9_HOST_FEAT_NS		1U	/* the ns channel is present */
#define P9_RINGSPINS		200000000u	/* a bounded wait: a few seconds */

/*
 * The 9P2000 messages this stage speaks.  Numbers are from the 9P2000
 * specification; the names are 9vm's.
 */
enum
{
	P9_Tversion	= 100,
	P9_Rversion,
	P9_Tauth	= 102,
	P9_Rauth,
	P9_Tattach	= 104,
	P9_Rattach,
	P9_Terror	= 106,
	P9_Rerror,
	P9_Tflush	= 108,
	P9_Rflush,
	P9_Twalk	= 110,
	P9_Rwalk,
	P9_Topen	= 112,
	P9_Ropen,
	P9_Tcreate	= 114,
	P9_Rcreate,
	P9_Tread	= 116,
	P9_Rread,
	P9_Twrite	= 118,
	P9_Rwrite,
	P9_Tclunk	= 120,
	P9_Rclunk,

	P9_Oread	= 0,
	P9_Owrite	= 1,
	P9_Orw		= 2,

	P9_Maxwelem	= 16,
	P9_Notag	= 0xFFFF,
};

#define P9_Nofid	0xFFFFFFFFu
#define P9_Readhdrsz	11		/* size[4] type[1] tag[2] count[4] */

/* A submission descriptor. buf_addr is a buffer index, not an address. */
typedef struct P9Slot P9Slot;
struct P9Slot
{
	uint16_t	tag;
	uint8_t		type;
	uint8_t		flags;
	uint32_t	fid;
	uint64_t	offset;
	uint32_t	count;
	uint64_t	buf_addr;
};

/* A completion descriptor. result is the buffer index that finished. */
typedef struct P9Comp P9Comp;
struct P9Comp
{
	uint16_t	tag;
	uint8_t		type;
	uint8_t		status;		/* 0: valid reply; >0: refused */
	uint32_t	count;
	uint64_t	result;
};

typedef struct P9TRing P9TRing;
struct P9TRing
{
	volatile uint32_t	head __attribute__((aligned(P9_CACHELINE)));
	volatile uint32_t	tail __attribute__((aligned(P9_CACHELINE)));
	P9Slot			slots[P9_RING_SIZE] __attribute__((aligned(P9_CACHELINE)));
};

typedef struct P9RRing P9RRing;
struct P9RRing
{
	volatile uint32_t	head __attribute__((aligned(P9_CACHELINE)));
	volatile uint32_t	tail __attribute__((aligned(P9_CACHELINE)));
	P9Comp			comps[P9_RING_SIZE] __attribute__((aligned(P9_CACHELINE)));
};

typedef struct P9Channel P9Channel;
struct P9Channel
{
	P9TRing	t_ring;
	P9RRing	r_ring;
};

typedef struct P9HostBuffer P9HostBuffer;
struct P9HostBuffer
{
	uint8_t	request[P9_HOST_MSIZE];
	uint8_t	response[P9_HOST_MSIZE];
};

typedef struct P9HostShared P9HostShared;
struct P9HostShared
{
	uint32_t	magic;
	uint32_t	version;
	uint32_t	features;
	P9Channel	channel;
	P9HostBuffer	buffer[P9_HOST_SLOTS];
	P9Channel	ns;
	P9HostBuffer	nsbuffer[P9_HOST_SLOTS];
};

/* One direction of the ring: a channel and the buffers behind it. */
typedef struct Ring Ring;
struct Ring
{
	P9Channel	*ch;
	P9HostBuffer	*buf;
	volatile int	lock;		/* serializes slot state and reaping */
	uint32_t	used;		/* buffers owned by an outstanding request */
	uint32_t	ready;		/* buffers holding an uncollected reply */
	uint32_t	len[P9_HOST_SLOTS];	/* reply length per buffer */
	uint32_t	status[P9_HOST_SLOTS];	/* 0: valid reply, 1: refused */
	uint32_t	inflight;
	uint32_t	maxinflight;
	uint32_t	nreq;
	uint32_t	nrep;
	/*
	 * The buffers in the order their completions were reaped, for the
	 * boot test to see that a server may answer out of order.  It is
	 * not used to route anything: that is what the per-buffer state is
	 * for.
	 */
	uint32_t	seq[P9_HOST_SLOTS];
	uint32_t	nseq;
	/*
	 * A ring is one 9P connection, and completions are collected from
	 * it without regard to which stream submitted them.  Two opens of
	 * #~/host would therefore race for each other's replies, and the
	 * one that did not submit the request would discard it.  The
	 * device enforces one open per channel; this is where it records
	 * that.
	 */
	int		open;
};

/* A request in flight. */
typedef struct RingMsg RingMsg;
struct RingMsg
{
	int		slot;		/* buffer index; -1 when not in flight */
	uint16_t	tag;
	uint32_t	len;		/* reply length, set by ringrecv */
};

/*
 * The channels this ABI version defines.  boardattach's table is the
 * only place a channel is added; above it, a board is an array of
 * independent rings and a name for each.
 */
#define P9_HOST_NCHAN	2

/*
 * The board.  Every channel lives in the same region; nchan is how many
 * the host actually offers, in #~ order.  Each channel is its own ring
 * with its own buffers: several can be in use at once.
 */
typedef struct Board Board;
struct Board
{
	P9HostShared	*sh;
	int		nchan;
	const char	*name[P9_HOST_NCHAN];
	Ring		chan[P9_HOST_NCHAN];
};

/* A qid, as on the wire: type[1] vers[4] path[8]. */
typedef struct P9Qid P9Qid;
struct P9Qid
{
	uint8_t		type;
	uint32_t	vers;
	uint64_t	path;
};

/*
 * A 9P2000 client over one ring.  It is small and synchronous per
 * message; the pipelined read keeps several messages in flight.
 */
typedef struct P9Client P9Client;
struct P9Client
{
	Ring		*ring;
	uint32_t	msize;		/* negotiated */
	uint16_t	nexttag;
	char		err[128];
};

/* One read of a pipelined batch.  data points into the ring's buffer. */
typedef struct P9Read P9Read;
struct P9Read
{
	RingMsg		msg;
	uint64_t	off;
	uint32_t	count;
	uint8_t		*data;
	uint32_t	len;
};

/* the board once attached, for the #~ device */
extern Board	*vmboard;

/* ring.c */
int	boardattach(Board*, uint64_t, uint64_t);
int	ringwaitany(Ring*, RingMsg*);
int	ringpoll(Ring*, RingMsg*);
Ring*	boardchan(Board*, int);
const char* boardchanname(Board*, int);
int	ringsubmit(Ring*, const void*, uint32_t, RingMsg*);
int	ringrecv(Ring*, RingMsg*);
void	ringdone(Ring*, RingMsg*);

/* p9.c */
int	p9mount(P9Client*, Ring*, uint32_t);
int	p9attach(P9Client*, uint32_t, const char*, const char*, P9Qid*);
int	p9walk(P9Client*, uint32_t, uint32_t, const char**, int, P9Qid*, int, int*);
int	p9open(P9Client*, uint32_t, int, P9Qid*, uint32_t*);
int	p9psubmit(P9Client*, uint32_t, uint64_t, uint32_t, int, P9Read*);
int	p9pcollect(P9Client*, int, P9Read*);
int	p9pread(P9Client*, uint32_t, uint64_t, uint32_t, int, P9Read*);
void	p9pdone(P9Client*, P9Read*, int);
int	p9clunk(P9Client*, uint32_t);
char*	p9err(P9Client*);

/* selftest.c */
void	ringselftest(Board*);

#endif
