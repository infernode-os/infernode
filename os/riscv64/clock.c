/*
 * The clock: the time CSR and SBI's set_timer.
 *
 * Every RISC-V hart has a time counter (the platform's mtime, read in
 * S-mode as the time CSR) running at a fixed rate the device tree
 * gives as /cpus/timebase-frequency: 10 MHz on QEMU's virt, 1 MHz on
 * a PolarFire SoC. An S-mode kernel cannot program the comparator
 * itself unless the hart has the Sstc extension, which the PolarFire's
 * U54 does not; SBI's set_timer does it on every hart, so that is what
 * is used. It also clears the pending timer interrupt, so re-arming is
 * acknowledging.
 *
 * Each hart ticks at HZ, as on arm64 (../arm64/clockgt.c): core 0
 * counts the ticks, every hart runs its own portclock Timer queue.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

enum
{
	Stie	= 1<<5,		/* sie: supervisor timer interrupts */
};

static u64int timebase;		/* time CSR ticks per second */
static u64int tickinterval;	/* time CSR ticks between clock interrupts */
static u64int ticks;		/* core 0's ticks since clockinit */

u64int
clockcount(void)
{
	u64int v;

	__asm__ volatile("rdtime %0" : "=r"(v));
	return v;
}

u64int
clockfreq(void)
{
	return timebase;
}

u64int
clockticks(void)
{
	return ticks;
}

void
microdelay(int us)
{
	u64int end, hz;

	boardwatchdogpoll();
	hz = timebase != 0 ? timebase : boardtimebase();
	end = clockcount() + (hz * (u64int)(uint)us) / 1000000;
	while(clockcount() < end)
		;
}

static void
armtick(void)
{
	sbisettimer(clockcount() + tickinterval);
}

void
clockinit(void)
{
	timebase = boardtimebase();
	if(timebase == 0)
		timebase = 10000000;	/* implausible, but do not divide by zero */
	tickinterval = timebase / HZ;
	ticks = 0;

	/* before the first timer: see ../arm64/clockgt.c on the tod deadlock */
	timersinit();
	todinit();

	armtick();
	__asm__ volatile("csrs sie, %0" :: "r"((ulong)Stie));
}

void
secclockinit(void)
{
	timersinitmach();
	armtick();
	__asm__ volatile("csrs sie, %0" :: "r"((ulong)Stie));
}

int
clockintr(Ureg *u)
{
	if(m->machno == 0){
		ticks++;
		boardwatchdogtick();
	}

	/* re-arm first: this also takes the pending interrupt down */
	armtick();

	timerintr(u, 0);

	/* the kernel profiler's buckets (os/port/devether.c) */
	{
		extern ulong profbuck[24576];
		ulong ix;

		ix = (u->pc - KTZERO) >> 6;
		if(ix < 24576)
			ainc(&profbuck[ix]);
	}
	return 1;
}

uvlong
fastticks(uvlong *hz)
{
	if(hz != nil)
		*hz = timebase != 0 ? timebase : boardtimebase();
	return clockcount();
}

/*
 * portclock's one-shot: a Timer due at `when'. The periodic tick
 * re-arms over it at the next interrupt, as on arm64.
 */
void
timerset(uvlong when)
{
	sbisettimer(when);
}
