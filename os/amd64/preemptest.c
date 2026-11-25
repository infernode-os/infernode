/*
 * os/amd64/preemptest.c -- the clock preempts, and timed sleep expires.
 *
 * The hog never sleeps and never yields; it only exists as a process if
 * another one can take the CPU away from it.  The watcher samples the
 * hog's counter, sleeps for 100 ms (a timeout, not a wakeup from another
 * process), samples again and requires the counter to have moved.  Both
 * halves are needed: without preemption the watcher never runs at all,
 * and without a clock the sleep never expires.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

static volatile ulong	hogcount;

static void
hog(void *a)
{
	ulong i;

	USED(a);
	for(i = 0; i < 1000000000UL; i++)
		hogcount++;
}

static void
watcher(void *a)
{
	ulong a0, a1;

	USED(a);
	a0 = hogcount;
	tsleep(&up->sleep, return0, nil, 100);
	a1 = hogcount;
	print("preempt: hog advanced %lud in 100ms\n", a1 - a0);
	if(a1 == a0){
		print("preemptest failed: no preemption\n");
		conshalt();
	}
	print("preemptest passed\n");
	conshalt();
}

void
preemptest(void)
{
	if(portprocinit() < 0){
		consprint("preemptest: no memory above the kernel\n");
		return;
	}

	kproc("hog", hog, nil, 0);
	kproc("watch", watcher, nil, 0);
	schedinit();
}
