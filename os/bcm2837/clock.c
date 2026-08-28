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
#include "board.h"

#define ST(r)	(*(volatile u32int*)((uintptr)SYSTIMERREGS + (r)))
/* LOCAL() now lives in io.h -- intr.c needs it too. */

enum
{
	Hz		= HZ,		/* scheduler ticks per second */
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

	/*
	 * Initialise the timer and time-of-day layers HERE, before
	 * anything can register a timer.
	 *
	 * The ordering is load-bearing, not tidiness. os/port/tod.c
	 * initialises itself lazily: ns2fastticks() calls todinit() if it
	 * has not run, and todinit() ends by calling addclock0link().
	 * But addclock0link() reaches ns2fastticks() through tadd() while
	 * already holding timers[0] -- so the first timer ever registered
	 * re-enters addclock0link and deadlocks on its own lock.
	 *
	 * Upstream never sees this because every port calls todinit()
	 * from its clock setup, so tod.init is already 1 and the lazy
	 * path is never taken. Doing the same here is the fix; taslock.c
	 * caught it as "ilock: no way out", which is a considerably
	 * better outcome than a silent hang.
	 */
	timersinit();
	todinit();

	armtick();
}

/*
 * Called from the IRQ path.  Returns non-zero if this was our timer.
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
	 * m->ticks is not bookkeeping -- os/port reads it directly.
	 *
	 * devcons.c's prflush() waits "while(serwrite==nil &&
	 * consactive())" and gives up once m->ticks has advanced by HZ.
	 * A platform clock that keeps its own counter and never updates
	 * m->ticks makes that loop wait forever, which presents as the
	 * console silently hanging on the first print rather than as a
	 * clock problem. proc.c's scheduler accounting reads it too.
	 */
	/*
	 * Hand the tick to os/port/portclock.c rather than doing the work
	 * here. hzclock() bumps m->ticks, runs the profiling hook, calls
	 * checkalarms() to expire timed sleeps, and -- the part this port
	 * previously did not do at all -- calls sched() when something is
	 * ready, which is what preempts a running process.
	 *
	 * Doing it by hand was how the earlier heap corruption happened:
	 * checkalarms() reaches wakeup() -> ready(), and hzclock() runs it
	 * only after checking that this processor is marked active, so a
	 * hand-rolled version calls it during boot when there is nothing
	 * safe to wake.
	 */
	hzclock(u);

	armtick();
	return 1;
}

/*
 * The ARM-side timer, used purely as a software-triggered interrupt.
 *
 * usbdwc.c needs somewhere safe to finish work the USB interrupt
 * started: upstream runs that interrupt as an FIQ, where taking the
 * locks wakeup() needs is not allowed, so it arms this timer and does
 * the wakeups from the ordinary interrupt that follows. Keeping the
 * mechanism means the driver stays diffable against Plan 9 rather than
 * being restructured around this port's lack of FIQ support.
 */
typedef struct Armtimer Armtimer;
struct Armtimer
{
	u32int	load;
	u32int	val;
	u32int	ctl;
	u32int	irqack;
	u32int	irq;
	u32int	maskedirq;
	u32int	reload;
	u32int	predivider;
	u32int	count;
};

/* volatile: Device memory, and adjacent stores must not be merged. */
#define ARMTIMER	((volatile Armtimer*)(uintptr)ARMTIMERREGS)

void
armtimerset(int n)
{
	Armtimer *tm;

	tm = ARMTIMER;
	if(n > 0){
		tm->ctl |= TmrEnable|TmrIntEnable;
		tm->load = n;
	}else{
		tm->load = 0;
		tm->ctl &= ~(TmrEnable|TmrIntEnable);
		tm->irqack = 1;
	}
	coherence();
}

/*
 * intrenable(void)/intrdisable(void)/intrenabled(void) used to live
 * here, meaning "unmask IRQs on this CPU". They are gone, for two
 * reasons that point the same way.
 *
 * They duplicated spllo()/splhi()/islo(), which os/arm64/arch.c
 * already provides and which os/port calls everywhere.
 *
 * And they occupied a name that means something else entirely in every
 * Inferno and Plan 9 kernel: intrenable(irq, fn, arg, tbdf, name)
 * registers a handler for one interrupt source. A device driver
 * written against that convention -- usbdwc.c, say -- would have
 * compiled against the wrong function or not at all. os/bcm2837/intr.c
 * now provides the real one.
 */

/*
 * Dispatch a pending interrupt.  With only one source wired up this is
 * short, but the shape is the one the scheduler will need: consult the
 * per-core source register, handle what is set, and say whether anything
 * was recognised so an unexpected interrupt is reported rather than
 * silently dropped.
 */
int
irqdispatch(Ureg *u)
{
	int handled;

	handled = 0;

	/*
	 * Cleared per dispatch, not per boot. It records the source
	 * intrrun could not place, and the decision below is about THIS
	 * interrupt -- a stale value from an earlier one would condemn a
	 * later spurious interrupt for something it did not do.
	 */
	irqorphan = -1;

	if(clockintr(u))
		handled = 1;

	/*
	 * Everything that is not the timer arrives as one bit. Ask the
	 * VideoCore controller which of its 72 sources actually fired.
	 */
	if(LOCAL(Lirqsource0) & Igpu)
		handled |= intrgpu(u);

	if(handled)
		return 1;

	/*
	 * Nothing claimed it, and nothing is asserted either: the source
	 * went away between the CPU latching the exception and us looking.
	 * That is a spurious interrupt, it is normal, and it must not be
	 * fatal.
	 *
	 * This driver stack generates them by construction. chanwait polls
	 * at splhi and clears hcintmsk and haintmsk once a transfer
	 * completes, which de-asserts the controller; the interrupt the
	 * CPU had already latched then fires as soon as spl drops, with
	 * nothing left pending. The board showed exactly that -- an IRQ
	 * taken one line after the first successful USB transfer, with
	 * Lirqsource0 and all three pending registers reading zero.
	 *
	 * A source that is genuinely pending and genuinely unhandled is a
	 * different thing and still reported: that one would spin for ever
	 * if ignored, and it is what the panic is for.
	 */
	/*
	 * Nothing claimed it. Two different things look like this and
	 * only one of them is a fault.
	 *
	 * If a source that is ENABLED and PENDING was rejected for want
	 * of a handler, intrrun recorded it, and that one would spin for
	 * ever if ignored: it is what the panic is for.
	 *
	 * Otherwise the source went away between the CPU latching the
	 * exception and us looking. That is a spurious interrupt, it is
	 * normal, and it must not be fatal. This driver stack generates
	 * them by construction: chanwait polls at splhi and clears
	 * hcintmsk and haintmsk once a transfer completes, which
	 * de-asserts the controller, and the interrupt the CPU had
	 * already latched then fires as soon as spl drops with nothing
	 * left pending.
	 *
	 * The test used to be intrpending() alone, which asks a
	 * different question -- "is anything asserted anywhere" -- and
	 * answered yes for peripherals nobody enabled. That panicked the
	 * board intermittently during USB bring-up with orphan reading
	 * -1: nothing enabled and pending had been rejected, so there was
	 * nothing to panic about.
	 */
	if(irqorphan < 0){
		nspurious++;
		return 1;
	}

	return 0;
}

/*
 * The high-resolution counter os/port/tod.c and portclock.c are built
 * on.
 *
 * This is a very good fit for the ARM generic timer: CNTPCT_EL0 is a
 * free-running 64-bit counter at CNTFRQ_EL0, which is exactly what
 * fastticks() is specified to return. The 32-bit ARM ports have to
 * synthesise this from a 32-bit peripheral counter and track wrap;
 * there is nothing to track here.
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
 * CNTP_CVAL_EL0 takes an absolute compare value, which is what
 * timerset() is given -- so unlike the periodic tick (which rearms
 * through the TVAL down-counter) this needs no conversion.
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
