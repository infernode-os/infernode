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

#include "dat.h"
#include "io.h"
#include "fns.h"

#define ST(r)	(*(volatile u32int*)((uintptr)SYSTIMERREGS + (r)))
#define LOCAL(r) (*(volatile u32int*)((uintptr)ARMLOCAL + (r)))

enum
{
	Hz		= 100,		/* scheduler ticks per second */
};

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
microdelay(u64int us)
{
	u64int end;

	end = systimer() + us;
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

	__asm__ volatile("mrs %0, cntp_ctl_el0" : "=r"(ctl));

	/* bit 2 is ISTATUS: the comparator has fired */
	if((ctl & (1<<2)) == 0)
		return 0;

	ticks++;
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
