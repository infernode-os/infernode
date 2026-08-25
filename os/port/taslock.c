#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

static void
lockloop(Lock *l, ulong pc)
{
	setpanic();
	print("lock loop 0x%lux key 0x%lux pc 0x%lux held by pc 0x%lux\n", l, l->key, pc, l->pc);
	panic("lockloop");
}

void
lock(Lock *l)
{
	int i;
	ulong pc;

	pc = getcallerpc(&l);
	if(up == 0) {
		if (_tas(&l->key) != 0) {
			for(i=0; ; i++) {
				if(_tas(&l->key) == 0)
					break;
				if (i >= 1000000) {
					lockloop(l, pc);
					break;
				}
			}
		}
		l->pc = pc;
		return;
	}

	for(i=0; ; i++) {
		if(_tas(&l->key) == 0)
			break;
		if (i >= 1000) {
			lockloop(l, pc);
			break;
		}
		if(conf.nmach == 1 && up->state == Running && islo()) {
			up->pc = pc;
			sched();
		}
	}
	l->pri = up->pri;
	up->pri = PriLock;
	l->pc = pc;
}

void
ilock(Lock *l)
{
	ulong x, pc;
	int i;

	pc = getcallerpc(&l);
	x = splhi();
	for(;;) {
		if(_tas(&l->key) == 0) {
			l->sr = x;
			l->pc = pc;
			return;
		}
		if(conf.nmach < 2)
			panic("ilock: no way out: pc 0x%lux: lock 0x%lux held by pc 0x%lux", pc, l, l->pc);
		for(i=0; ; i++) {
			if(l->key == 0)
				break;
			clockcheck();
			if (i > 100000) {
				lockloop(l, pc);
				break;
			}
		}
	}
}

int
canlock(Lock *l)
{
	if(_tas(&l->key))
		return 0;
	if(up){
		l->pri = up->pri;
		up->pri = PriLock;
	}
	l->pc = getcallerpc(&l);
	return 1;
}

void
unlock(Lock *l)
{
	int p;

	if(l->key == 0)
		print("unlock: not locked: pc %lux\n", getcallerpc(&l));
	p = l->pri;
	l->pc = 0;
	/*
	 * The barrier goes BEFORE the store that releases the lock, not
	 * after it.
	 *
	 * Releasing is "everything I did under this lock is visible, and
	 * only then is the lock free". Ordering it the other way round
	 * lets the store that frees the lock be observed before the
	 * writes it was protecting, so another observer can take the
	 * lock and read data that has not arrived yet -- and _tas()
	 * acquires with ldaxr, so the acquire side is already correct
	 * and would give no warning.
	 *
	 * Latent rather than live in this kernel: the secondary cores
	 * are parked, so there is no other observer to see the wrong
	 * order. It becomes real on the day SMP is brought up, and it
	 * would be a very unpleasant thing to go looking for then.
	 */
	coherence();
	l->key = 0;
	if(up){
		up->pri = p;

		/*
		 * islo(), which upstream does not check.
		 *
		 * Rescheduling here is a courtesy: the lock is free, so if
		 * something more urgent is waiting, yield to it. But it is
		 * only a courtesy where yielding is LEGAL, and it is not
		 * legal when the caller is holding interrupts off.
		 *
		 * sched() ends by resuming the process through
		 * "procrestore(up); spllo();" -- it unconditionally ENABLES
		 * interrupts. So an unlock() inside an splhi() region hands
		 * the caller back a machine with interrupts on, silently
		 * discarding the mask it established and expects to undo
		 * itself with splx(). Every invariant that region was
		 * protecting is then unprotected, while the code that set
		 * it up carries on believing otherwise.
		 *
		 * This is Plan 9's rule -- its unlock() spells the same
		 * condition "&& islo()" -- and Inferno has simply never
		 * needed it, because almost nothing in the tree calls
		 * sleep() with interrupts already off.
		 *
		 * usbdwc.c does, on every transfer: chanwait() takes
		 * splhi(), sets the channel's interrupt mask, and sleeps.
		 * When the controller has ALREADY completed the transfer --
		 * which is the normal case under emulation, and a race on
		 * real hardware -- the condition function is true on entry,
		 * sleep() takes its early-return path, and unlock(&up->rlock)
		 * reschedules from inside the splhi region. The process is
		 * requeued, resumed, and re-enters the same unlock; the
		 * stack pointer descends a few hundred bytes each round and
		 * the kernel stack overflows some tens of rounds later, at
		 * which point the guard word finally reports a corrupt
		 * process on a stack that has nothing to do with the driver.
		 */
		if(up->state == Running && anyhigher() && islo())
			sched();
	}
}

void
iunlock(Lock *l)
{
	ulong sr;

	if(l->key == 0)
		print("iunlock: not locked: pc %lux\n", getcallerpc(&l));
	sr = l->sr;
	l->pc = 0;
	/*
	 * The barrier goes BEFORE the store that releases the lock, not
	 * after it.
	 *
	 * Releasing is "everything I did under this lock is visible, and
	 * only then is the lock free". Ordering it the other way round
	 * lets the store that frees the lock be observed before the
	 * writes it was protecting, so another observer can take the
	 * lock and read data that has not arrived yet -- and _tas()
	 * acquires with ldaxr, so the acquire side is already correct
	 * and would give no warning.
	 *
	 * Latent rather than live in this kernel: the secondary cores
	 * are parked, so there is no other observer to see the wrong
	 * order. It becomes real on the day SMP is brought up, and it
	 * would be a very unpleasant thing to go looking for then.
	 */
	coherence();
	l->key = 0;
	splxpc(sr);
}
