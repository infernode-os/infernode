/*
 * os/amd64/clocktest.c -- fastticks, the timer queue and the time of day.
 *
 * A periodic clock0link timer counts its calls while a process sleeps
 * for 100 ms.  The sleep expiry proves checkalarms and the ticks; the
 * periodic timer proves timeradd/timerintr; and the elapsed time read
 * from todget around the sleep checks that the TSC rate is right, not
 * merely nonzero.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

static volatile ulong	tcount;

static void
tickfn(void)
{
	tcount++;
}

static void
clockproc(void *a)
{
	vlong t0, t1;
	ulong d;

	USED(a);
	tcount = 0;
	(void)addclock0link(tickfn, 0);	/* every HZ tick */
	t0 = todget(nil);
	tsleep(&up->sleep, return0, nil, 100);
	t1 = todget(nil);
	d = (ulong)((t1 - t0) / 1000000);
	print("clock: slept %lud ms, %lud timer calls\n", d, tcount);
	if(d < 80 || d > 400 || tcount < 3){
		print("clocktest failed\n");
		conshalt();
	}
	print("clocktest passed\n");
	conshalt();
}

void
clocktest(void)
{
	if(portprocinit() < 0){
		consprint("clocktest: no memory above the kernel\n");
		return;
	}
	kproc("clock", clockproc, nil, 0);
	schedinit();
}
