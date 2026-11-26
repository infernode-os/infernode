/*
 * ring.c -- the guest side of 9vm's #~ host ring.
 *
 * The host puts a P9HostShared at the top of guest RAM and serves it from
 * a thread on another core.  A request is a complete 9P message written
 * into one of the eight 32 KiB buffers, published on the submission ring
 * as a descriptor naming that buffer.  The host answers into the same
 * buffer and publishes a completion naming it again.  Nothing is shared
 * by pointer, so the guest and the host may map the region at different
 * addresses.
 *
 * Up to eight requests are in flight, one per buffer.  Completions are
 * collected into per-buffer state, so the guest does not care in what
 * order the host completes them: the ns channel, whose server answers in
 * its own time, may complete them in any order.
 *
 * There is no timer and no interrupt at this stage: a wait is a bounded
 * spin.  The bound exists so a dead host fails the request instead of
 * hanging the machine.
 */

#include <stddef.h>
#include <string.h>
#include "board.h"

/* The host's 9ring.h is the authority for all of this. */
_Static_assert(sizeof(P9Slot) == 32, "P9Slot layout");
_Static_assert(sizeof(P9Comp) == 16, "P9Comp layout");
_Static_assert(sizeof(P9TRing) == 8320, "P9TRing layout");
_Static_assert(sizeof(P9RRing) == 4224, "P9RRing layout");
_Static_assert(offsetof(P9HostShared, channel) == 64, "channel offset");
_Static_assert(offsetof(P9HostShared, ns) == 64 + sizeof(P9Channel) +
	P9_HOST_SLOTS * sizeof(P9HostBuffer), "ns offset");

/*
 * One ring is shared by every process and interrupt that uses the
 * channel, so the slot pool, the ready set and the completion reaper
 * are serialized.  A plain spinlock is enough: the timer handler never
 * touches a ring, so a preempted holder always resumes.
 */
static void
rlock(Ring *r)
{
	while(__atomic_exchange_n(&r->lock, 1, __ATOMIC_ACQUIRE))
		__asm__ volatile("pause");
}

static void
runlock(Ring *r)
{
	__atomic_store_n(&r->lock, 0, __ATOMIC_RELEASE);
}

static uint32_t
g32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1]<<8 |
		(uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}

/* Publishes a descriptor; 0 when the ring is full. */
static int
tsubmit(P9TRing *t, const P9Slot *s)
{
	uint32_t head, tail;

	head = __atomic_load_n(&t->head, __ATOMIC_RELAXED);
	tail = __atomic_load_n(&t->tail, __ATOMIC_ACQUIRE);
	if(head - tail >= P9_RING_SIZE)
		return 0;
	t->slots[head & P9_RING_MASK] = *s;
	__atomic_store_n(&t->head, head + 1, __ATOMIC_RELEASE);
	return 1;
}

/* Takes a completion; 0 when there is none. */
static int
rpoll(P9RRing *r, P9Comp *c)
{
	uint32_t tail, head;

	tail = __atomic_load_n(&r->tail, __ATOMIC_RELAXED);
	head = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
	if(tail == head)
		return 0;
	*c = r->comps[tail & P9_RING_MASK];
	__atomic_store_n(&r->tail, tail + 1, __ATOMIC_RELEASE);
	return 1;
}

static void
ringinit(Ring *r, P9Channel *ch, P9HostBuffer *buf)
{
	int i;

	r->ch = ch;
	r->buf = buf;
	r->lock = 0;
	r->open = 0;
	r->used = 0;
	r->ready = 0;
	r->inflight = 0;
	r->maxinflight = 0;
	r->nreq = 0;
	r->nrep = 0;
	r->nseq = 0;
	for(i = 0; i < P9_HOST_SLOTS; i++){
		r->len[i] = 0;
		r->status[i] = 0;
	}
}

/*
 * Takes every completion the host has published and records it against
 * its buffer.  A completion the guest cannot make sense of marks the
 * buffer failed, never valid: the host owns the ring's contents.
 */
static void
reap(Ring *r)
{
	P9Comp c;
	P9HostBuffer *b;
	uint8_t *resp;
	uint32_t len;
	int ok;

	while(rpoll(&r->ch->r_ring, &c)){
		r->nrep++;
		if(c.result >= P9_HOST_SLOTS)
			continue;
		ok = 0;
		if(c.status == 0 && c.count >= 7 && c.count <= P9_HOST_MSIZE){
			b = &r->buf[c.result];
			resp = b->response;
			len = g32(resp);
			if(len == c.count && resp[4] == c.type &&
			   (uint32_t)(resp[5] | resp[6]<<8) == c.tag){
				r->len[c.result] = len;
				r->status[c.result] = 0;
				ok = 1;
			}
		}
		if(!ok)
			r->status[c.result] = 1;
		r->ready |= 1u<<c.result;
		if(r->nseq < P9_HOST_SLOTS)
			r->seq[r->nseq++] = c.result;
	}
}

/*
 * The channels of ABI version 1.  A channel's descriptors sit at a fixed
 * offset in the region and its buffers follow them, so a later version
 * that adds a ring is a row here (or, if it ever declares a count, a
 * walk) and nothing above boardattach changes.
 */
static struct
{
	const char	*name;
	uint32_t	feature;	/* 0: always offered */
	uint32_t	offset;		/* of the P9Channel in P9HostShared */
} chans[P9_HOST_NCHAN] = {
	{ "host", 0, offsetof(P9HostShared, channel) },
	{ "ns", P9_HOST_FEAT_NS, offsetof(P9HostShared, ns) },
};

int
boardattach(Board *b, uint64_t pa, uint64_t len)
{
	P9HostShared *sh;
	uint8_t *base;
	uint32_t need;
	int i;

	if(len < sizeof(P9HostShared)){
		consprint("infernode/9vm: ring region is shorter than its header\n");
		return -1;
	}
	/*
	 * The first GiB is identity mapped, so the physical address is
	 * the address to use; a ring beyond that is not reachable yet.
	 */
	if(pa == 0 || pa + len < pa || pa + len > 0x40000000ULL){
		consprint("infernode/9vm: ring region is outside the identity map\n");
		return -1;
	}
	sh = (P9HostShared*)(uintptr_t)pa;
	if(sh->magic != P9_HOST_MAGIC || sh->version != P9_HOST_VERSION){
		consprint("infernode/9vm: not a 9vm ring: magic ");
		consprinthex(sh->magic);
		consprint(" version ");
		consprintdec(sh->version);
		consprint("\n");
		return -1;
	}

	memset(b, 0, sizeof(*b));
	b->sh = sh;
	base = (uint8_t*)sh;
	for(i = 0; i < P9_HOST_NCHAN; i++){
		if(chans[i].feature != 0 &&
		   (sh->features & chans[i].feature) == 0)
			continue;
		need = chans[i].offset + sizeof(P9Channel) +
			P9_HOST_SLOTS * sizeof(P9HostBuffer);
		if(need > len){
			consprint("infernode/9vm: channel ");
			consprint(chans[i].name);
			consprint(" does not fit the region\n");
			return -1;
		}
		ringinit(&b->chan[b->nchan],
			(P9Channel*)(base + chans[i].offset),
			(P9HostBuffer*)(base + chans[i].offset + sizeof(P9Channel)));
		b->name[b->nchan] = chans[i].name;
		b->nchan++;
	}

	consprint("infernode/9vm: ring at ");
	consprinthex((uint64_t)(uintptr_t)sh);
	consprint(", ");
	consprintdec(len);
	consprint(" bytes, features ");
	consprinthex(sh->features);
	consprint(", ");
	consprintdec(b->nchan);
	consprint(" channel(s)\n");
	for(i = 0; i < b->nchan; i++){
		consprint("infernode/9vm: #~/");
		consprintdec(i);
		consprint(" ");
		consprint(b->name[i]);
		consprint("\n");
	}
	return 0;
}

Ring*
boardchan(Board *b, int i)
{
	if(i < 0 || i >= b->nchan)
		return 0;
	return &b->chan[i];
}

const char*
boardchanname(Board *b, int i)
{
	if(i < 0 || i >= b->nchan)
		return "?";
	return b->name[i];
}

/*
 * Copies one complete 9P message into a free buffer and publishes it.
 * The message's own header must agree with the descriptor; the host
 * checks that too and refuses the request if it does not.
 */
int
ringsubmit(Ring *r, const void *msg, uint32_t len, RingMsg *m)
{
	const uint8_t *p = msg;
	P9Slot s;
	uint32_t i;

	m->slot = -1;
	m->len = 0;
	if(len < 7 || len > P9_HOST_MSIZE)
		return -1;

	rlock(r);
	for(i = 0; i < P9_HOST_SLOTS; i++)
		if((r->used & 1u<<i) == 0)
			break;
	if(i == P9_HOST_SLOTS){
		runlock(r);
		return -1;
	}

	memmove(r->buf[i].request, p, len);
	memset(&s, 0, sizeof(s));
	s.tag = (uint16_t)(p[5] | p[6]<<8);
	s.type = p[4];
	s.count = len;
	s.buf_addr = i;
	if(!tsubmit(&r->ch->t_ring, &s)){
		runlock(r);
		return -1;
	}

	r->used |= 1u<<i;
	r->inflight++;
	if(r->inflight > r->maxinflight)
		r->maxinflight = r->inflight;
	r->nreq++;
	m->slot = i;
	m->tag = s.tag;
	runlock(r);
	return 0;
}

/*
 * Waits for this request's reply.  Completions that arrive for other
 * requests are reaped and kept, so a caller may hold several requests
 * open and collect them in any order.
 *
 * Returns 0 with the reply, -1 when the spin bound expired (the request
 * is STILL PUBLISHED: its buffer must not be reused), or -2 when the
 * host refused it (the completion was consumed, so the buffer is free).
 */
int
ringrecv(Ring *r, RingMsg *m)
{
	uint32_t spins;
	int fail;

	if(m->slot < 0 || m->slot >= P9_HOST_SLOTS)
		return -1;
	for(spins = 0; spins < P9_RINGSPINS; spins++){
		rlock(r);
		reap(r);
		if(r->ready & 1u<<m->slot){
			fail = r->status[m->slot];
			r->ready &= ~(1u<<m->slot);
			m->len = r->len[m->slot];
			runlock(r);
			return fail ? -2 : 0;
		}
		runlock(r);
		__asm__ volatile("pause");
	}
	return -1;
}

/*
 * Waits for any completion, for the stream device: a 9P client writes
 * requests and reads replies by tag, so the device does not need to
 * know which request a reply belongs to, only that one is ready.
 * Returns 0, -1 on timeout, -2 on a refused request (slot freed).
 */
int
ringwaitany(Ring *r, RingMsg *m)
{
	uint32_t spins, i;

	for(spins = 0; spins < P9_RINGSPINS; spins++){
		rlock(r);
		reap(r);
		if(r->ready){
			for(i = 0; i < P9_HOST_SLOTS; i++)
				if(r->ready & 1u<<i)
					break;
			r->ready &= ~(1u<<i);
			m->slot = i;
			m->len = r->len[i];
			if(r->status[i] != 0){
				/* refused: the completion was consumed */
				r->used &= ~(1u<<i);
				if(r->inflight > 0)
					r->inflight--;
				m->slot = -1;
				runlock(r);
				return -2;
			}
			runlock(r);
			return 0;
		}
		runlock(r);
		__asm__ volatile("pause");
	}
	return -1;
}

/*
 * Takes one ready completion without waiting, for retiring requests a
 * client wrote and never read.  -1 when none, -2 when one was refused
 * and its buffer has been released.
 */
int
ringpoll(Ring *r, RingMsg *m)
{
	uint32_t i;
	int st;

	m->slot = -1;
	rlock(r);
	reap(r);
	if(r->ready == 0){
		runlock(r);
		return -1;
	}
	for(i = 0; i < P9_HOST_SLOTS; i++)
		if(r->ready & 1u<<i)
			break;
	r->ready &= ~(1u<<i);
	m->len = r->len[i];
	st = r->status[i];
	if(st != 0){
		r->used &= ~(1u<<i);
		if(r->inflight > 0)
			r->inflight--;
		/*
		 * The completion is consumed and the buffer released, so
		 * the caller must NOT ringdone() it -- but it still has to
		 * forget the request, which is what the slot is for.
		 */
		m->slot = i;
		runlock(r);
		return -2;
	}
	m->slot = i;
	runlock(r);
	return 0;
}

/* Returns the buffer to the pool. */
void
ringdone(Ring *r, RingMsg *m)
{
	if(m->slot < 0 || m->slot >= P9_HOST_SLOTS)
		return;
	rlock(r);
	r->used &= ~(1u<<m->slot);
	r->ready &= ~(1u<<m->slot);
	if(r->inflight > 0)
		r->inflight--;
	m->slot = -1;
	runlock(r);
}
