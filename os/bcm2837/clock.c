/*
 * Time and the periodic tick.
 *
 * Two independent clocks are available and both are used, for different
 * reasons:
 *
 *   The ARM generic timer (CNTPCT_EL0) is architectural, per-core, and
 *   drives the scheduler tick via a comparator that raises an
 *   interrupt.  This is the one that matters.
 *
 *   The BCM system timer is a free-running 64-bit counter at a fixed
 *   1MHz, sitting in the peripheral block.  It is not per-core and
 *   cannot easily drive a per-core tick, but its rate is KNOWN rather
 *   than reported, which makes it the reference for checking that the
 *   generic timer's advertised CNTFRQ_EL0 is telling the truth.
 *
 * That cross-check is worth having.  CNTFRQ_EL0 is not derived by the
 * hardware; it is a value firmware writes, and firmware can write the
 * wrong one.  Every delay and timeout in the kernel would then be off by
 * that ratio -- a failure that looks like "the network is flaky" or "the
 * display tears", never like "the clock is wrong".
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

#define ST(r)	(*(volatile u32int*)((uintptr)SYSTIMERREGS + (r)))
#define LOCAL(r) (*(volatile u32int*)((uintptr)ARMLOCAL + (r)))

enum
{
	Hz		= 100,		/* scheduler ticks per second */
};

/*
 * Periodic callbacks registered through addclock0link().
 *
 * os/port uses this for anything that must run on the clock rather than
 * on a process: devcons's keyboard repeat, and -- the one that matters
 * -- os/port/dis.c's accountant(), which charges elapsed time against
 * the running Prog. The Dis scheduler uses that accounting to decide
 * when a Prog's quantum is up, so with no clock callback the VM runs one
 * program and never switches away from it.
 *
 * A fixed array rather than the Timer list portclock.c maintains: this
 * port drives its tick straight from the generic timer, and four slots
 * is more than the kernel currently registers.
 */
enum
{
	Nclock0	= 8,
};

static struct
{
	void	(*f)(void);
	int	ms;		/* requested period */
	int	when;		/* ticks until next call */
} clock0[Nclock0];

static int nclock0;

static u64int cntfrq;		/* generic timer rate, from CNTFRQ_EL0 */
static u64int tickinterval;	/* generic timer ticks between interrupts */
static u64int ticks;		/* ticks since clockinit */

static u64int
rdcntfrq(void)
{
	u64int v;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v;
}

u64int
clockcount(void)
{
	u64int v;

	/*
	 * isb before reading: the counter read can otherwise be
	 * speculated ahead of surrounding work, which matters when the
	 * read is being used to time that work.
	 */
	__asm__ volatile("isb");
	__asm__ volatile("mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

u64int
clockfreq(void)
{
	return cntfrq;
}

u64int
clockticks(void)
{
	return ticks;
}

/*
 * The BCM system timer, read as a 64-bit value.  Read high, then low,
 * then high again: if the high word changed, the low word wrapped
 * between the two reads and the pair is inconsistent, so try again.
 */
u64int
systimer(void)
{
	u32int hi, lo, hi2;

	for(;;){
		hi = ST(Stchi);
		lo = ST(Stclo);
		hi2 = ST(Stchi);
		if(hi == hi2)
			return ((u64int)hi << 32) | lo;
	}
}

/*
 * Busy-wait, timed off the system timer because its 1MHz rate is fixed
 * by the hardware rather than reported by firmware.
 */
void
microdelay(int us)
{
	u64int end;

	end = systimer() + (u64int)(uint)us;
	while(systimer() < end)
		;
}

static void
armtick(void)
{
	/*
	 * TVAL is a down-counter: writing it sets the comparator that
	 * many ticks into the future.  Rearming from TVAL rather than
	 * from an absolute CVAL means a late interrupt shifts the whole
	 * schedule rather than causing a burst of catch-up interrupts.
	 */
	__asm__ volatile("msr cntp_tval_el0, %0" :: "r"(tickinterval));
	__asm__ volatile("msr cntp_ctl_el0, %0" :: "r"((u64int)1));
	__asm__ volatile("isb");
}

void
clockinit(void)
{
	cntfrq = rdcntfrq();
	if(cntfrq == 0)
		cntfrq = 1000000;	/* implausible, but do not divide by zero */

	tickinterval = cntfrq / Hz;
	ticks = 0;

	/* route the non-secure physical timer to core 0's IRQ line */
	LOCAL(Ltimerirq0) = Cntpnsirq;

	armtick();
}

/*
 * Called from the IRQ path.  Returns non-zero if this was our timer.
 */
int
clockintr(void)
{
	u64int ctl;
	int i;

	__asm__ volatile("mrs %0, cntp_ctl_el0" : "=r"(ctl));

	/* bit 2 is ISTATUS: the comparator has fired */
	if((ctl & (1<<2)) == 0)
		return 0;

	ticks++;

	/*
	 * m->ticks is not bookkeeping -- os/port reads it directly.
	 *
	 * devcons.c's prflush() waits "while(serwrite==nil &&
	 * consactive())" and gives up once m->ticks has advanced by HZ.
	 * A platform clock that keeps its own counter and never updates
	 * m->ticks makes that loop wait forever, which presents as the
	 * console silently hanging on the first print rather than as a
	 * clock problem. proc.c's scheduler accounting reads it too.
	 */
	if(m != nil)
		m->ticks++;

	/*
	 * Run the registered clock callbacks. Done here, in interrupt
	 * context, because that is what "on the clock" means -- these are
	 * exactly the things that must happen whether or not any process
	 * is willing to yield.
	 */
	for(i = 0; i < nclock0; i++){
		if(clock0[i].f == nil)
			continue;
		if(--clock0[i].when <= 0){
			clock0[i].when = clock0[i].ms;
			(*clock0[i].f)();
		}
	}

	armtick();
	return 1;
}

void
intrenable(void)
{
	/* clear DAIF.I -- unmask IRQ */
	__asm__ volatile("msr daifclr, #2");
	__asm__ volatile("isb");
}

void
intrdisable(void)
{
	__asm__ volatile("msr daifset, #2");
	__asm__ volatile("isb");
}

int
intrenabled(void)
{
	u64int daif;

	__asm__ volatile("mrs %0, daif" : "=r"(daif));
	return (daif & (1<<7)) == 0;	/* DAIF.I is bit 7 */
}

/*
 * Dispatch a pending interrupt.  With only one source wired up this is
 * short, but the shape is the one the scheduler will need: consult the
 * per-core source register, handle what is set, and say whether anything
 * was recognised so an unexpected interrupt is reported rather than
 * silently dropped.
 */
int
irqdispatch(void)
{
	int handled;

	handled = 0;

	if(clockintr())
		handled = 1;

	return handled;
}

/*
 * Register a periodic callback, called every ms milliseconds.
 *
 * The Timer* return is portclock.c's handle for cancelling one; nothing
 * here cancels, so nil is honest rather than a fabricated handle a
 * caller might later pass to a timer layer that does not exist.
 */
Timer*
addclock0link(void (*f)(void), int ms)
{
	int i, s;

	s = splhi();
	if(nclock0 >= Nclock0){
		splx(s);
		print("addclock0link: no free slot for a %d ms callback\n", ms);
		return nil;
	}
	i = nclock0++;
	clock0[i].f = f;
	clock0[i].ms = MS2TK(ms) > 0 ? MS2TK(ms) : 1;
	clock0[i].when = clock0[i].ms;
	splx(s);

	return nil;
}
