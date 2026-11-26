/*
 * #~ -- the 9vm host ring as device files.
 *
 * #~/host and #~/ns are byte streams carrying complete 9P2000 messages:
 * a write submits one T-message to that channel's ring, a read returns
 * one R-message in the order the host completes them.  devmnt (and the
 * ringdevtest boot) speak 9P through them exactly as they would to a
 * socket, which is the point: the transport is the ring, not virtio.
 *
 * Reads buffer a reply that does not fit in one read; a client that
 * reads four bytes for the size and then the rest works unmodified.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "board.h"

enum
{
	Qdir,
	Qhost,
	Qns,
};

static Dirtab ringdir[] =
{
	".",	{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"host",	{Qhost},		0,	0600,
	"ns",	{Qns},			0,	0600,
};

typedef struct Raux Raux;
struct Raux
{
	Ring	*r;
	RingMsg	msg;
	int	slot;		/* the reply being drained, or -1 */
	long	len;
	long	rp;
	int	pend[P9_HOST_SLOTS];	/* written, reply not yet consumed */
	int	npend;
};

static void
pendadd(Raux *a, int slot)
{
	if(a->npend < P9_HOST_SLOTS)
		a->pend[a->npend++] = slot;
}

static void
penddel(Raux *a, int slot)
{
	int i;

	for(i = 0; i < a->npend; i++)
		if(a->pend[i] == slot){
			a->pend[i] = a->pend[--a->npend];
			return;
		}
}

/* ns exists only when the host advertises it */
static int
ringgen(Chan *c, char *name, Dirtab *tab, int ntab, int i, Dir *dp)
{
	if(i == Qns && (vmboard == nil || vmboard->nchan < 2))
		return -1;
	return devgen(c, name, tab, ntab, i, dp);
}

static Chan*
ringattach(char *spec)
{
	if(vmboard == nil)
		error("9ring: no host transport");
	return devattach('~', spec);
}

static Walkqid*
ringwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, ringdir, nelem(ringdir), ringgen);
}

static int
ringstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, ringdir, nelem(ringdir), ringgen);
}

static Chan*
ringopen(Chan *c, int omode)
{
	Raux *a;
	Ring *r;

	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Ebadarg);
		c->mode = omode;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}
	switch((int)c->qid.path){
	case Qhost:
		r = &vmboard->chan[0];
		break;
	case Qns:
		if(vmboard->nchan < 2)
			error("9ring: the host offers no ns channel");
		r = &vmboard->chan[1];
		break;
	default:
		error(Eperm);
		return nil;
	}
	/*
	 * One stream per ring.  ringwaitany() collects whichever reply
	 * completes first and cannot tell which open submitted it, so a
	 * second open would steal the first one's completions (and its
	 * reader would discard replies not in its own tag queue).  A
	 * future demultiplexer can lift this; a second connection needs a
	 * second channel, which is what #~ already offers.
	 */
	if(r->open)
		error("9ring: channel already open");
	a = mallocz(sizeof(*a), 1);
	if(a == nil)
		error(Enomem);
	r->open = 1;
	a->r = r;
	a->slot = -1;
	c->aux = a;
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = P9_HOST_MSIZE;
	return c;
}

static void
ringclose(Chan *c)
{
	Raux *a;

	if(c->qid.type & QTDIR)
		return;
	a = c->aux;
	if(a == nil)
		return;
	if(a->slot >= 0){
		penddel(a, a->slot);
		ringdone(a->r, &a->msg);
		a->slot = -1;
	}
	/*
	 * Retire replies that arrived for requests this stream wrote and
	 * the client never read.  Anything still unreplied stays
	 * reserved: the host may still write its buffer, and handing it
	 * to another request is how a stale reply gets accepted.
	 */
	{
		RingMsg m;
		int i, r;

		for(i = 0; i < P9_RINGSPINS && a->npend > 0; i++){
			r = ringpoll(a->r, &m);
			if(r == 0){
				penddel(a, m.slot);
				ringdone(a->r, &m);
				continue;
			}
			if(r == -2){
				penddel(a, m.slot);
				continue;
			}
			__asm__ volatile("pause");
		}
	}
	/*
	 * A request the host never answered keeps its buffer reserved, and
	 * a completion that arrived after the drain would be handed to
	 * whichever open reader is next.  Fail closed: the ring stays
	 * unavailable rather than serving a reply to the wrong stream.  A
	 * second connection needs a second channel, not a second open.
	 */
	if(a->npend > 0)
		print("9ring: %d replies uncollected; channel left closed\n",
			a->npend);
	else
		a->r->open = 0;
	free(a);
	c->aux = nil;
}

static long
ringread(Chan *c, void *va, long n, vlong off)
{
	Raux *a;
	RingMsg m;
	long got;
	int r;

	USED(off);
	if(c->qid.type & QTDIR)
		error(Eperm);
	if(n <= 0)
		return 0;
	a = c->aux;
	if(a->slot < 0){
		r = ringwaitany(a->r, &m);
		if(r < 0)
			error("9ring: no reply from the host");
		a->msg = m;
		a->slot = m.slot;
		a->len = m.len;
		a->rp = 0;
	}
	got = a->len - a->rp;
	if(got > n)
		got = n;
	memmove(va, a->r->buf[a->slot].response + a->rp, got);
	a->rp += got;
	if(a->rp == a->len){
		penddel(a, a->slot);
		ringdone(a->r, &a->msg);
		a->slot = -1;
	}
	return got;
}

static long
ringwrite(Chan *c, void *va, long n, vlong off)
{
	Raux *a;
	RingMsg m;
	int i;

	USED(off);
	if(c->qid.type & QTDIR)
		error(Eperm);
	if(n < 7 || n > P9_HOST_MSIZE)
		error("9ring: bad 9P message length");
	a = c->aux;
	/*
	 * Eight requests may be outstanding.  A ninth write waits: the
	 * slot is freed when a reader drains a reply, and the scheduler
	 * keeps that reader running while this one spins.
	 */
	for(i = 0; i < P9_RINGSPINS; i++){
		if(ringsubmit(a->r, va, n, &m) == 0){
			pendadd(a, m.slot);
			return n;
		}
		__asm__ volatile("pause");
	}
	error("9ring: no free ring slot");
	return -1;
}

Dev hostringdevtab = {
	'~',
	"hostring",

	devreset,
	devinit,
	devshutdown,
	ringattach,
	ringwalk,
	ringstat,
	ringopen,
	devcreate,
	ringclose,
	ringread,
	devbread,
	ringwrite,
	devbwrite,
	devremove,
	devwstat,
};
