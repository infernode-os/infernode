/*
 * Imported from upstream Inferno os/port/random.c.
 *
 * DIVERGENCE FROM UPSTREAM: the embedded QLock in the random-buffer
 * struct is named. See os/bcm2837/README.md.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

static struct
{
	QLock	q;
	Rendez	producer;
	Rendez	consumer;
	ulong	randomcount;
	uchar	buf[1024];
	uchar	*ep;
	uchar	*rp;
	uchar	*wp;
	uchar	next;
	uchar	bits;
	uchar	wakeme;
	uchar	filled;
	int	target;
	int	kprocstarted;
	ulong	randn;
} rb;

static int
rbnotfull(void*)
{
	int i;

	i = rb.wp - rb.rp;
	if(i < 0)
		i += sizeof(rb.buf);
	return i < rb.target;
}

static int
rbnotempty(void*)
{
	return rb.wp != rb.rp;
}

static void
genrandom(void*)
{
	setpri(PriBackground);

	for(;;) {
		for(;;)
			if(++rb.randomcount > 100000)
				break;
		if(anyhigher())
			sched();
		if(rb.filled || !rbnotfull(0))
			sleep(&rb.producer, rbnotfull, 0);
	}
}

/*
 *  produce random bits in a circular buffer
 */
static void
randomclock(void)
{
	uchar *p;

	if(rb.randomcount == 0)
		return;

	if(!rbnotfull(0)) {
		rb.filled = 1;
		return;
	}

	rb.bits = (rb.bits<<2) ^ (rb.randomcount&3);
	rb.randomcount = 0;

	rb.next += 2;
	if(rb.next != 8)
		return;

	rb.next = 0;
	*rb.wp ^= rb.bits ^ *rb.rp;
	p = rb.wp+1;
	if(p == rb.ep)
		p = rb.buf;
	rb.wp = p;

	if(rb.wakeme)
		wakeup(&rb.consumer);
}

void
randominit(void)
{
	/* Frequency close but not equal to HZ */
	addclock0link(randomclock, 13);
	rb.target = 16;
	rb.ep = rb.buf + sizeof(rb.buf);
	rb.rp = rb.wp = rb.buf;

	/*
	 * Prime the pool from the hardware generator.
	 *
	 * Without this the FIRST caller to want randomness sleeps in
	 * randomread() until the clock-jitter producer has stirred enough
	 * bits in -- and if that producer is not running, or is not
	 * getting scheduled, it sleeps forever. That is not a theoretical
	 * risk: it hung this kernel the first time anything opened a
	 * network conversation, because setlport() calls nrand() to pick a
	 * port and nrand() seeds itself from here.
	 *
	 * Priming removes the dependency on the producer ever having run,
	 * which is what makes the failure impossible rather than unlikely.
	 * The jitter producer still runs and still stirs the pool; it is
	 * simply no longer the only source.
	 */
	{
		int got;

		/*
		 * One byte short of the buffer, deliberately. rb is a
		 * circular buffer in which wp == rp means EMPTY, so filling
		 * it completely wraps wp back onto rp and the pool reads as
		 * empty again -- priming it perfectly and achieving nothing.
		 */
		got = hwrandom(rb.buf, sizeof(rb.buf) - 1);
		if(got > 0)
			rb.wp = rb.buf + got;
	}
}

/*
 *  consume random bytes from a circular buffer
 */
ulong
randomread(void *xp, ulong n)
{
	int i, sofar;
	uchar *e, *p;

	p = xp;

	qlock(&rb.q);
	if(waserror()){
		qunlock(&rb.q);
		nexterror();
	}
	if(!rb.kprocstarted){
		rb.kprocstarted = 1;
		kproc("genrand", genrandom, nil, 0);
	}

	for(sofar = 0; sofar < n; sofar += i){
		i = rb.wp - rb.rp;
		if(i == 0){
			rb.wakeme = 1;
			wakeup(&rb.producer);
			sleep(&rb.consumer, rbnotempty, 0);
			rb.wakeme = 0;
			continue;
		}
		if(i < 0)
			i = rb.ep - rb.rp;
		if((i+sofar) > n)
			i = n - sofar;
		memmove(p + sofar, rb.rp, i);
		e = rb.rp + i;
		if(e == rb.ep)
			e = rb.buf;
		rb.rp = e;
	}
	if(rb.filled && rb.wp == rb.rp){
		i = 2*rb.target;
		if(i > sizeof(rb.buf) - 1)
			i = sizeof(rb.buf) - 1;
		rb.target = i;
		rb.filled = 0;
	}
	poperror();
	qunlock(&rb.q);

	wakeup(&rb.producer);

	return n;
}
