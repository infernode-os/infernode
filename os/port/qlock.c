/*
 * Imported from upstream Inferno os/port/qlock.c.
 *
 * DIVERGENCE FROM UPSTREAM: RWlock's embedded Lock is named, so the
 * container-passes lock(l) become lock(&l->l). See
 * os/bcm2837/README.md.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

void
qlock(QLock *q)
{
	Proc *p, *mp;

	lock(&q->use);
	if(!q->locked) {
		q->locked = 1;
		unlock(&q->use);
		return;
	}
	p = q->tail;
	mp = up;
	if(p == 0)
		q->head = mp;
	else
		p->qnext = mp;
	q->tail = mp;
	mp->qnext = 0;
	SETSTATE(mp, Queueing);
	up->qpc = getcallerpc(&q);
	unlock(&q->use);
	sched();
}

int
canqlock(QLock *q)
{
	if(!canlock(&q->use))
		return 0;
	if(q->locked){
		unlock(&q->use);
		return 0;
	}
	q->locked = 1;
	unlock(&q->use);
	return 1;
}

void
qunlock(QLock *q)
{
	Proc *p;

	lock(&q->use);
	p = q->head;
	if(p) {
		q->head = p->qnext;
		if(q->head == 0)
			q->tail = 0;
		unlock(&q->use);
		ready(p);
		return;
	}
	q->locked = 0;
	unlock(&q->use);
}

void
rlock(RWlock *l)
{
	qlock(&l->x);		/* wait here for writers and exclusion */
	lock(&l->l);
	l->readers++;
	canqlock(&l->k);	/* block writers if we are the first reader */
	unlock(&l->l);
	qunlock(&l->x);
}

/*
 * Same as rlock but punts if a writer holds the lock or waits for it,
 * and only then.
 *
 * It used to punt whenever canqlock(&l->x) failed, but every reader
 * takes x too, for the few instructions of rlock and canrlock, and
 * canqlock also fails while anyone holds x's spinlock. So on several
 * cores canrlock failed at random beside another reader, and its
 * callers in os/ip (ipoput4, the loopback and ether readers) drop the
 * packet when it fails: an ICMP echo over loopback, sent while TCP
 * moved packets over the same interface, was lost and its reader never
 * woke (bcm2837 CI). Writers are counted under l from before they wait
 * for x until they have let go of it, so the answer here is decided
 * under l alone and x is never touched: with no writer counted, k is
 * free or held by readers, and nothing else is touching it.
 */
int
canrlock(RWlock *l)
{
	lock(&l->l);
	if(l->writers){
		unlock(&l->l);
		return 0;
	}
	l->readers++;
	canqlock(&l->k);	/* block writers if we are the first reader */
	unlock(&l->l);
	return 1;
}

void
runlock(RWlock *l)
{
	lock(&l->l);
	if(--l->readers == 0)	/* last reader out allows writers */
		qunlock(&l->k);
	unlock(&l->l);
}

void
wlock(RWlock *l)
{
	lock(&l->l);
	l->writers++;		/* canrlock punts from here on */
	unlock(&l->l);
	qlock(&l->x);		/* wait here for writers and exclusion */
	qlock(&l->k);		/* wait here for last reader */
}

void
wunlock(RWlock *l)
{
	qunlock(&l->k);
	qunlock(&l->x);
	lock(&l->l);
	l->writers--;
	unlock(&l->l);
}
