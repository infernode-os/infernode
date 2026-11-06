#include	"dat.h"
#include	"fns.h"
#include	"error.h"

/*
 * Track per-kproc held-lock count (up may be nil on non-kproc threads
 * such as the SDL mainloop — skip those).  disfault() uses it to
 * fail-stop on a fault taken while a spin lock is held: longjmp
 * recovery cannot release the lock, so continuing manufactures a
 * silent deadlock (pool lock + VM token stranding — the zombie-freeze
 * class of failure) instead of a diagnosable panic.
 */
static void
locktaken(void)
{
	if(up != nil)
		up->nlocks++;
}

void
lock(Lock *l)
{
	int i;

	if(_tas(&l->val) == 0){
		locktaken();
		return;
	}
	for(i=0; i<100; i++){
		if(_tas(&l->val) == 0){
			locktaken();
			return;
		}
		osyield();
	}
	for(i=1;; i++){
		if(_tas(&l->val) == 0){
			locktaken();
			return;
		}
		osmillisleep(i*10);
		if(i > 100){
			osyield();
			i = 1;
		}
	}
}

int
canlock(Lock *l)
{
	if(_tas(&l->val) == 0){
		locktaken();
		return 1;
	}
	return 0;
}

void
unlock(Lock *l)
{
	if(up != nil && up->nlocks > 0)
		up->nlocks--;
#ifdef _MSC_VER
	_InterlockedExchange(&l->val, 0);
#else
	__atomic_store_n(&l->val, 0, __ATOMIC_RELEASE);
#endif
}

void
qlock(QLock *q)
{
	Proc *p;

	lock(&q->use);
	if(!q->locked) {
		q->locked = 1;
		unlock(&q->use);
		return;
	}
	p = q->tail;
	if(p == 0)
		q->head = up;
	else
		p->qnext = up;
	q->tail = up;
	up->qnext = 0;
	unlock(&q->use);
	osblock();
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
		osready(p);
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
 * canqlock also fails while anyone holds x's spinlock. So canrlock
 * failed at random beside another reader: devcons's kernel print sent
 * the text to the console instead of /dev/kprint while someone read it.
 * Writers are counted under l from before they wait for x until they
 * have let go of it, so the answer here is decided under l alone and x
 * is never touched: with no writer counted, k is free or held by
 * readers, and nothing else is touching it. (os/port/qlock.c has had
 * the same fix.)
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
