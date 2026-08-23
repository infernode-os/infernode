/*
 * Spin locks, without the scheduler.
 *
 * This is a deliberate stand-in for os/port/taslock.c, not a competing
 * design. Upstream's version is written against the Proc layer -- it
 * consults `up` to decide whether the caller can be descheduled while
 * spinning, adjusts up->pri to avoid priority inversion, and calls
 * sched() when a single-processor machine would otherwise deadlock.
 * None of that exists yet, and inventing a fake `up` to satisfy it
 * would be worse than admitting the gap.
 *
 * What is here is the subset upstream itself takes when up is nil: a
 * plain test-and-set spin. That is exactly correct for the current
 * kernel, which is single-core with no processes -- and it is what
 * xalloc.c and the fmt engine need in order to run at all.
 *
 * REPLACE THIS with os/port/taslock.c once proc.c lands. The signatures
 * are upstream's precisely so that dropping the real file in requires
 * deleting this one and nothing else.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

/*
 * Spinning forever on a lock nobody will release is indistinguishable
 * from a hang. Bound it, and report where the lock was taken -- on a
 * single core a contended lock can only mean a deadlock or corruption,
 * both of which are worth saying out loud.
 */
enum
{
	Spinlimit = 100*1000*1000,
};

static void
lockloop(Lock *l, uintptr pc)
{
	uartputs("\nlock: stuck spinning, taken at pc=");
	uartputx(l->pc);
	uartputs(" waiter pc=");
	uartputx(pc);
	uartputs("\n");
	panic("lockloop");
}

void
lock(Lock *l)
{
	uintptr pc;
	ulong i;

	pc = getcallerpc(&l);
	for(i = 0;; i++){
		if(_tas(&l->key) == 0)
			break;
		if(i >= Spinlimit){
			lockloop(l, pc);
			break;
		}
	}
	l->pc = pc;
}

int
canlock(Lock *l)
{
	if(_tas(&l->key))
		return 0;
	l->pc = getcallerpc(&l);
	return 1;
}

void
unlock(Lock *l)
{
	if(l->key == 0)
		uartputs("unlock: not locked\n");
	l->pc = 0;
	/*
	 * coherence() before releasing: a store to data the lock protects
	 * must not be visible after the release that lets another core in.
	 */
	coherence();
	l->key = 0;
}

/*
 * ilock also masks interrupts, and iunlock restores the level that was
 * saved -- not "enabled". A lock taken from an interrupt handler and
 * released with interrupts unconditionally enabled would re-enter the
 * handler.
 */
void
ilock(Lock *l)
{
	uintptr pc;
	ulong x, i;

	pc = getcallerpc(&l);
	x = splhi();
	for(i = 0;; i++){
		if(_tas(&l->key) == 0)
			break;
		if(i >= Spinlimit){
			splx(x);
			lockloop(l, pc);
			break;
		}
	}
	l->sr = x;
	l->pc = pc;
}

void
iunlock(Lock *l)
{
	ulong sr;

	if(l->key == 0)
		uartputs("iunlock: not locked\n");
	sr = l->sr;
	l->pc = 0;
	coherence();
	l->key = 0;
	splx(sr);
}
