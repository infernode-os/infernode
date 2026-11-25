/*
 * os/amd64/clock.c -- the free-running clock os/port's tod and timers
 * are built on.
 *
 * The counter is the TSC.  Its rate is measured once against the 8254's
 * channel 2, polled as a one-shot: program 10 ms, count TSC ticks, and
 * derive Hz.  That is the only calibration this kernel needs; the PIT's
 * channel 0 stays the interrupt source, and timers are checked on each
 * tick (timerset() has nothing finer to program).
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "console.h"
#include "port.h"

#define PITBASE	1193182		/* the 8254's input clock, Hz */

static uvlong	tscfreq;

static uvlong
rdtsc(void)
{
	uint32 lo, hi;

	__asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
	return ((uvlong)hi << 32) | lo;
}

void
clockinit(void)
{
	uint32 count;
	uvlong t0, t1;
	uint8 tmp;
	int i;

	count = PITBASE/100;		/* 10 ms */
	tmp = inb(0x61);
	outb(0x61, (uint8)((tmp & ~0x02) | 0x01));	/* gate on, speaker off */
	outb(0x43, 0xB0);				/* ch2, mode 0, lo/hi */
	outb(0x42, count & 0xff);
	outb(0x42, (count >> 8) & 0xff);

	t0 = rdtsc();
	/* OUT goes high at terminal count; a VM with no channel-2 output
	 * leaves it low, so the wait is bounded and the fallback below
	 * takes over rather than hanging the boot. */
	for(i = 0; i < 1000000 && (inb(0x61) & 0x20) == 0; i++)
		;
	t1 = rdtsc();
	outb(0x61, tmp);

	tscfreq = 0;
	if(t1 > t0)
		tscfreq = (t1 - t0) * PITBASE / count;

	/*
	 * Some virtual machines do not emulate the 8254's channel 2
	 * output (bit 5 of port 0x61), so the one-shot above ends
	 * immediately.  Fall back to the channel 0 tick that is already
	 * driving interrupts: ten of them are a tenth of a second.
	 */
	if(tscfreq < 100000000ULL || tscfreq > 100000000000ULL){
		uvlong k0, r0, r1;

		k0 = tickcount();
		r0 = rdtsc();
		spllo();
		while(tickcount() < k0 + 10)
			__asm__ volatile("hlt");
		r1 = rdtsc();
		(void)splhi();
		tscfreq = (r1 - r0) * HZ / 10;
	}

	if(tscfreq < 100000000ULL || tscfreq > 100000000000ULL){
		/*
		 * The one-shot did not behave as the PC timer does (some
		 * virtual machines do not emulate channel 2).  A wrong
		 * rate would make every sleep and every timestamp wrong,
		 * so say so and use a nominal rate.
		 */
		tscfreq = 1000000000ULL;
		consprint("infernode/amd64: clock: no TSC calibration, assuming 1 GHz\n");
	}else{
		consprint("infernode/amd64: clock: TSC ");
		consprintdec(tscfreq/1000000);
		consprint(" MHz\n");
	}
}

uvlong
fastticks(uvlong *hz)
{
	if(hz != nil)
		*hz = tscfreq;
	return rdtsc();
}

/*
 * The PIT ticks at HZ regardless; the timer queue is walked from the
 * tick, so nothing to program when the next timer is not due yet.
 */
void
timerset(uvlong when)
{
	USED(when);
}

/* x86 caches are coherent; no instruction-cache maintenance is needed. */
void
kmapinval(void)
{
}

/* A calibrated wait, now that the TSC's rate is known. */
void
microdelay(int us)
{
	uvlong d, t;

	if(us <= 0)
		return;
	d = (uvlong)us * tscfreq / 1000000ULL;
	t = fastticks(nil);
	while(fastticks(nil) - t < d)
		;
}
