/*
 * Imported from upstream Inferno os/port/portclock.c.
 *
 * DIVERGENCE FROM UPSTREAM: embedded Locks are named. Timers embeds
 * one, and portdat.h's Timer does too. See os/bcm2837/README.md.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

struct Timers
{
	Lock	l;
	Timer	*head;
};

static Timers timers[MAXMACH];

ulong intrcount[MAXMACH];
ulong fcallcount[MAXMACH];

static uvlong
tadd(Timers *tt, Timer *nt)
{
	Timer *t, **last;

	/* Called with tt locked */
	assert(nt->tt == nil);
	switch(nt->tmode){
	default:
		panic("timer");
		break;
	case Trelative:
		assert(nt->tns > 0);
		nt->twhen = fastticks(nil) + ns2fastticks(nt->tns);
		break;
	case Tabsolute:
		nt->twhen = tod2fastticks(nt->tns);
		break;
	case Tperiodic:
		assert(nt->tns >= 100000);	/* At least 100 µs period */
		if(nt->twhen == 0){
			/* look for another timer at same frequency for combining */
			for(t = tt->head; t; t = t->tnext){
				if(t->tmode == Tperiodic && t->tns == nt->tns)
					break;
			}
			if (t)
				nt->twhen = t->twhen;
			else
				nt->twhen = fastticks(nil);
		}
		nt->twhen += ns2fastticks(nt->tns);
		break;
	}

	for(last = &tt->head; t = *last; last = &t->tnext){
		if(t->twhen > nt->twhen)
			break;
	}
	nt->tnext = *last;
	*last = nt;
	nt->tt = tt;
	if(last == &tt->head)
		return nt->twhen;
	return 0;
}

static uvlong
tdel(Timer *dt)
{

	Timer *t, **last;
	Timers *tt;

	tt = dt->tt;
	if (tt == nil)
		return 0;
	for(last = &tt->head; t = *last; last = &t->tnext){
		if(t == dt){
			assert(dt->tt);
			dt->tt = nil;
			*last = t->tnext;
			break;
		}
	}
	if(last == &tt->head && tt->head)
		return tt->head->twhen;
	return 0;
}

/* add or modify a timer */
void
timeradd(Timer *nt)
{
	Timers *tt;
	vlong when;

	if (nt->tmode == Tabsolute){
		when = todget(nil);
		if (nt->tns <= when){
	//		if (nt->tns + MS2NS(10) <= when)	/* small deviations will happen */
	//			print("timeradd (%lld %lld) %lld too early 0x%lux\n",
	//				when, nt->tns, when - nt->tns, getcallerpc(&nt));
			nt->tns = when;
		}
	}
	/* Must lock Timer struct before Timers struct */
	ilock(&nt->l);
	if(tt = nt->tt){
		ilock(&tt->l);
		tdel(nt);
		iunlock(&tt->l);
	}
	tt = &timers[m->machno];
	ilock(&tt->l);
	when = tadd(tt, nt);
	if(when)
		timerset(when);
	iunlock(&tt->l);
	iunlock(&nt->l);
}


void
timerdel(Timer *dt)
{
	Timers *tt;
	uvlong when;

	ilock(&dt->l);
	if(tt = dt->tt){
		ilock(&tt->l);
		when = tdel(dt);
		if(when && tt == &timers[m->machno])
			timerset(tt->head->twhen);
		iunlock(&tt->l);
	}
	iunlock(&dt->l);
}

void
hzclock(Ureg *ur)
{
	m->ticks++;
	if(m->proc)
		m->proc->pc = ur->pc;

	kmapinval();

	if(kproftick != nil)
		kproftick(ur->pc);

	if((active.machs&(1<<m->machno)) == 0)
		return;

	if(active.exiting) {
		print("someone's exiting\n");
		exit(0);
	}

	checkalarms();

	/*
	 * Preempt -- but never re-entrantly.
	 *
	 * sched() re-enables interrupts (spllo) when the process is
	 * resumed, and it does that while still inside this interrupt
	 * handler, several frames deep. The next tick can therefore arrive
	 * before this one has unwound, call hzclock again, and preempt
	 * again. Nothing bounds that: each nesting keeps its Ureg and its
	 * frames on the SAME kernel stack, so the stack only grows.
	 *
	 * It ends with the process running off the bottom of its kstack,
	 * down through the heap and into .bss, where the frames land on
	 * libkern's format-handler table and the next print() branches
	 * through a pointer with a formatted character written into it.
	 * Raising KSTACK from 16K to 64K did not help, which is what
	 * proved it recursion rather than depth.
	 *
	 * The flag lives in Proc rather than Mach because sched() does not
	 * return until THIS process is scheduled again: it brackets one
	 * process's preemption exactly. A Mach-wide flag would stay set
	 * while some other process ran and would suppress its preemption
	 * too.
	 */
	if(up && up->state == Running && !up->inpreempt){
		if(anyready()){
			up->inpreempt = 1;
			sched();
			splhi();
			up->inpreempt = 0;
		}
	}
}

void
timerintr(Ureg *u, uvlong)
{
	Timer *t;
	Timers *tt;
	uvlong when, now;
	int callhzclock;
	static int sofar;

	intrcount[m->machno]++;
	callhzclock = 0;
	tt = &timers[m->machno];
	now = fastticks(nil);
	ilock(&tt->l);
	while(t = tt->head){
		/*
		 * No need to ilock t here: any manipulation of t
		 * requires tdel(t) and this must be done with a
		 * lock to tt held.  We have tt, so the tdel will
		 * wait until we're done
		 */
		when = t->twhen;
		if(when > now){
			timerset(when);
			iunlock(&tt->l);
			if(callhzclock)
				hzclock(u);
			return;
		}
		tt->head = t->tnext;
		assert(t->tt == tt);
		t->tt = nil;
		fcallcount[m->machno]++;
		iunlock(&tt->l);
		if(t->tf)
			(*t->tf)(u, t);
		else
			callhzclock++;
		ilock(&tt->l);
		if(t->tmode == Tperiodic)
			tadd(tt, t);
	}
	iunlock(&tt->l);
}

void
timersinit(void)
{
	Timer *t;

	todinit();
	t = malloc(sizeof(*t));
	t->tmode = Tperiodic;
	t->tt = nil;
	t->tns = 1000000000/HZ;
	t->tf = nil;
	timeradd(t);
}

Timer*
addclock0link(void (*f)(void), int ms)
{
	Timer *nt;
	uvlong when;

	/* Synchronize to hztimer if ms is 0 */
	nt = malloc(sizeof(Timer));
	if(ms == 0)
		ms = 1000/HZ;
	nt->tns = (vlong)ms*1000000LL;
	nt->tmode = Tperiodic;
	nt->tt = nil;
	nt->tf = (void (*)(Ureg*, Timer*))f;

	ilock(&timers[0].l);
	when = tadd(&timers[0], nt);
	if(when)
		timerset(when);
	iunlock(&timers[0].l);
	return nt;
}

/*
 *  This tk2ms avoids overflows that the macro version is prone to.
 *  It is a LOT slower so shouldn't be used if you're just converting
 *  a delta.
 */
ulong
tk2ms(ulong ticks)
{
	uvlong t, hz;

	t = ticks;
	hz = HZ;
	t *= 1000L;
	t = t/hz;
	ticks = t;
	return ticks;
}

ulong
ms2tk(ulong ms)
{
	/* avoid overflows at the cost of precision */
	if(ms >= 1000000000/HZ)
		return (ms/1000)*HZ;
	return (ms*HZ+500)/1000;
}
