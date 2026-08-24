/*
 * Time and the periodic tick on the virt machine.
 *
 * The ARM generic timer does all of it. That is the whole difference
 * from BCM2837, which has a second, independently-rated 1MHz counter in
 * its peripheral block and uses it both as a delay reference and as a
 * cross-check on CNTFRQ_EL0.
 *
 * There is no equivalent here. virt's only other clock is a PL031 RTC
 * ticking at 1Hz, far too coarse to time the 50ms interval that check
 * needs. So microdelay() is derived from CNTPCT_EL0 -- the same counter
 * whose rate is in question -- and boardclockcheck() says plainly that
 * it cannot verify anything rather than performing a comparison that
 * would only ever compare the timer against itself and always agree.
 *
 * That is not a gap worth papering over. It is one of the concrete ways
 * the emulator is weaker than the board, and the boot log should say so
 * rather than print a reassuring line.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

enum
{
	Hz		= 100,		/* scheduler ticks per second */
};

static u64int cntfrq;		/* generic timer rate, from CNTFRQ_EL0 */
static u64int tickinterval;	/* generic timer ticks between interrupts */
static u64int ticks;		/* ticks since clockinit */
static u64int spurious;		/* IARs that resolved to nothing */

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

u64int
clockspurious(void)
{
	return spurious;
}

/*
 * Busy-wait.
 *
 * Timed off the generic timer because it is the only counter on this
 * machine. On BCM2837 this deliberately uses the OTHER clock, so that a
 * lying CNTFRQ_EL0 cannot make a delay wrong and a measurement of that
 * delay right at the same time. Nothing here can offer that.
 */
void
microdelay(int us)
{
	u64int end, per;

	per = cntfrq / 1000000;
	if(per == 0)
		per = 1;
	end = clockcount() + (u64int)(uint)us * per;
	while(clockcount() < end)
		;
}

static void
armtick(void)
{
	/*
	 * TVAL is a down-counter: writing it sets the comparator that
	 * many ticks into the future. Rearming from TVAL rather than
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
		cntfrq = 62500000;	/* implausible, but do not divide by zero */

	tickinterval = cntfrq / Hz;
	ticks = 0;

	/*
	 * Let the timer PPI through the GIC.
	 *
	 * gicinit() ran in boardprobe(), well before this. The ordering
	 * matters and is invisible if it is wrong: arming the comparator
	 * below succeeds either way, so a timer enabled before its
	 * controller exists produces a kernel that boots normally and
	 * never ticks.
	 */
	gicenable(Ppitimer);

	/*
	 * Initialise the timer and time-of-day layers HERE, before
	 * anything can register a timer.
	 *
	 * os/port/tod.c initialises itself lazily: ns2fastticks() calls
	 * todinit() if it has not run, and todinit() ends by calling
	 * addclock0link(). But addclock0link() reaches ns2fastticks()
	 * through tadd() while already holding timers[0] -- so the first
	 * timer ever registered re-enters addclock0link and deadlocks on
	 * its own lock. Every upstream port calls todinit() from its
	 * clock setup, which is why upstream never sees it.
	 */
	timersinit();
	todinit();

	armtick();
}

/*
 * Called from the IRQ path once the GIC has said this was the timer.
 * Returns non-zero if the comparator had in fact fired.
 */
int
clockintr(Ureg *u)
{
	u64int ctl;

	__asm__ volatile("mrs %0, cntp_ctl_el0" : "=r"(ctl));

	/* bit 2 is ISTATUS: the comparator has fired */
	if((ctl & (1<<2)) == 0)
		return 0;

	ticks++;

	/*
	 * Hand the tick to os/port/portclock.c rather than doing the
	 * work here. hzclock() bumps m->ticks, runs the profiling hook,
	 * calls checkalarms() to expire timed sleeps, and calls sched()
	 * when something is ready -- which is what preempts a running
	 * process. It also checks that this processor is marked active
	 * first, which is what stops any of that from running during
	 * boot when there is nothing safe to wake.
	 */
	hzclock(u);

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
 * Dispatch a pending interrupt.
 *
 * The GIC's acknowledge cycle frames the whole function: reading IAR
 * both identifies the interrupt and masks it, and it stays masked until
 * the same value goes back to EOIR. So every path out of here -- the
 * handled one, the unclaimed one, and the spurious one -- must reach
 * the EOI. An early return that skips it does not fail; it delivers
 * that interrupt exactly once and then never again.
 *
 * A spurious IAR (1023) is normal rather than an error: it is what the
 * GIC returns when an interrupt was withdrawn between asserting and
 * being acknowledged. It is counted, not reported, because reporting it
 * would turn a benign race into log noise -- but a count that climbs is
 * worth being able to see, which is what clockspurious() is for.
 */
int
irqdispatch(Ureg *u)
{
	u32int iar;
	int irq, handled;

	iar = gicack();
	irq = iar & Gicidmask;

	if(irq >= Gicspurious){
		spurious++;
		return 1;		/* nothing to EOI: it was withdrawn */
	}

	handled = 0;
	if(irq == Ppitimer)
		handled = clockintr(u);

	/*
	 * EOI before returning, including when nothing claimed it. The
	 * caller panics on an unclaimed interrupt, and a panic that left
	 * the GIC mid-acknowledge would mask the line for whatever ran
	 * next -- so the acknowledge cycle is closed first, and the
	 * verdict reported afterwards.
	 */
	giceoi(iar);
	return handled;
}

/*
 * The high-resolution counter os/port/tod.c and portclock.c are built
 * on. CNTPCT_EL0 is a free-running 64-bit counter at CNTFRQ_EL0, which
 * is exactly what fastticks() is specified to return -- the 32-bit ARM
 * ports have to synthesise this and track wrap; there is nothing to
 * track here.
 */
uvlong
fastticks(uvlong *hz)
{
	if(hz != nil)
		*hz = cntfrq;
	return clockcount();
}

/*
 * Program the timer comparator for an absolute fastticks value.
 *
 * A deadline already in the past must still fire: the architecture
 * raises the interrupt as soon as the counter is >= the comparator, so
 * setting a stale value is self-correcting rather than a lost timer.
 */
void
timerset(uvlong when)
{
	__asm__ volatile("msr cntp_cval_el0, %0" :: "r"(when));
	__asm__ volatile("msr cntp_ctl_el0, %0" :: "r"((u64int)1));
	__asm__ volatile("isb");
}
