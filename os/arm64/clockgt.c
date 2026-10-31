/*
 * Time and the periodic tick.
 *
 * The ARM generic timer and nothing else. CNTPCT_EL0 is a free-running
 * 64-bit counter at CNTFRQ_EL0; a comparator on it raises a
 * per-processor interrupt, INTID 30 on the GIC, and that is the
 * scheduler's tick on every core.
 *
 * Nearly all of this file is os/bcm2837/clock.c, and the reasoning in
 * its comments -- why timerintr and not hzclock, why todinit is called
 * from here, why each core needs its own Timer -- was learned on the
 * board and is kept word for word, because it is about os/port and the
 * architecture, not about either machine. What the board has and virt
 * does not is a SECOND clock: the BCM system timer, whose rate is
 * fixed by the hardware, and which the board uses for microdelay and
 * for checking that firmware wrote the right number into CNTFRQ. Here
 * the counter and the number that describes it both come from QEMU,
 * there is no firmware between them to get it wrong, and microdelay
 * counts CNTPCT directly.
 *
 * What differs is the routing. The board points the timer at a core
 * through its local-interrupt block; here each core enables INTID 30
 * in its own banked copy of the GIC's per-processor enables (gic.c).
 *
 * This was os/arm64/clockgt.c. It is here because a Raspberry Pi 4 is the
 * same in every respect that matters to a clock -- generic timer, GIC,
 * interrupt 30 -- and a board whose timer is routed some other way
 * (os/bcm2837/clock.c, through the BCM2836 local-interrupt block) has
 * the harness leave this file out (ARCHSKIP).
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../arm64/ureg.h"	/* the profiler reads u->pc */
#include "board.h"

enum
{
	Hz		= HZ,		/* scheduler ticks per second */
};

static u64int cntfrq;		/* generic timer rate, from CNTFRQ_EL0 */
static u64int tickinterval;	/* generic timer ticks between interrupts */
static u64int ticks;		/* core 0's ticks since clockinit; see clockintr */

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
 * Busy-wait, timed off the generic timer's counter.
 *
 * Usable from the first instruction: the counter runs whether or not
 * anything has been initialised, and until clockinit has read CNTFRQ
 * this reads it for itself. boardwatchdogpoll is the board's hook for
 * a boot watchdog that must be fed while interrupts are still masked;
 * virt has no watchdog and its hook does nothing, but the call stays
 * so the two microdelays have the same shape.
 */
void
microdelay(int us)
{
	u64int end, hz;

	boardwatchdogpoll();
	hz = cntfrq != 0 ? cntfrq : rdcntfrq();
	end = clockcount() + (hz * (u64int)(uint)us) / 1000000;
	while(clockcount() < end)
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

	/* the non-secure physical timer's interrupt, for this core */
	gicppienable(IRQcntpnsirq);

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
 * A secondary core's clock, and -- because it is the first thing a
 * secondary does that needs one -- its interrupt controller. The GIC's
 * CPU interface and the per-processor enables are banked per core, so
 * each core turns its own on; core 0's were done by intrinit.
 *
 * clockinit() proper ran once on core 0; the other cores reuse its
 * tickinterval, enable their own timer interrupt, and arm their first
 * tick.
 *
 * Routing and arming are not enough, and for a long time on the board
 * they were all this did. clockintr() hands every tick to
 * portclock.c's timerintr(), which walks timers[m->machno] -- THIS
 * core's queue -- and the only thing that makes a tick into a clock
 * (m->ticks, checkalarms, the active.exiting check, preemption) is a
 * periodic Timer with a nil tf sitting on that queue. timersinit()
 * made exactly one, on core 0's queue, and so cores 1-3 took a
 * thousand interrupts a second and did nothing with any of them.
 * smpcheck() in main.c asserts the opposite at boot now.
 *
 * timersinitmach() puts this core's hzclock Timer on this core's queue.
 * It does not re-run todinit(): time of day is one machine-wide clock,
 * initialised by core 0 before any secondary was released.
 */
void
secclockinit(void)
{
	gicsecinit();
	gicppienable(IRQcntpnsirq);
	timersinitmach();
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

	/*
	 * Core 0's count only. This is the counter the boot-time rate
	 * check reads through clockticks(), before any other core exists;
	 * it has no per-core meaning, and four cores doing ++ on one word
	 * without a lock lose increments. The per-core count that matters
	 * is m->ticks, which hzclock() advances below.
	 */
	if(m->machno == 0)
		ticks++;

	/* the boot watchdog is core 0's to keep alive; see board.c */
	if(m->machno == 0)
		boardwatchdogtick();

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
	/*
	 * timerintr, not hzclock directly -- and the difference is every
	 * consumer of addclock0link().
	 *
	 * The portable timer layer was fully initialised here
	 * (timersinit, todinit, a real timerset) and its dispatcher was
	 * never called: this line went straight to hzclock, so the
	 * Timer queue -- including the periodic entry timersinit creates
	 * whose whole purpose is to CALL hzclock -- never ran, and
	 * every addclock0link timer on the system was silently dead.
	 * randomclock never ticked in the life of this port; nobody
	 * noticed because the entropy pool grew a second source. The
	 * USB driver's channel re-arm tick is what finally needed the
	 * chain alive.
	 *
	 * timerintr's timerset() programs CVAL for the earliest
	 * deadline, and armtick() below immediately re-arms TVAL for
	 * the fixed millisecond -- TVAL wins, so dispatch stays at HZ
	 * granularity, which every ms-scale periodic here is fine with.
	 */
	timerintr(u, 0);

	/*
	 * A sampling profiler, one array index per tick.
	 *
	 * Every tick buckets the interrupted PC at 64-byte granularity;
	 * the ELF's symbol table turns offsets back into function names
	 * offline. Reading #l/ether0/ifstats returns "offset count"
	 * lines and resets the counts, so two reads bracket a workload.
	 * This is how the question "where does the CPU actually go at
	 * 2.4MB/s?" was answered with numbers instead of theories --
	 * the answer (GC and scheduler, not the network path) is in the
	 * README.
	 */
	/*
	 * ainc, not ++: every core runs this on every tick, and two cores
	 * sampling into the same bucket at once would otherwise lose one
	 * of the samples -- a profiler that quietly under-reports the hot
	 * spot is worse than one that is honestly noisy.
	 */
	{
		extern ulong profbuck[24576];
		ulong ix;

		ix = (u->pc - KTZERO) >> 6;
		if(ix < 24576)
			ainc(&profbuck[ix]);
	}

	armtick();
	return 1;
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
