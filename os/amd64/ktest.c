/*
 * os/amd64/ktest.c -- the boot tests for traps, the timer and threads.
 *
 * kerneltest runs on a command line that asks for it: a breakpoint proves
 * the exception path returns, the timer proves interrupts arrive, and two
 * workers prove the run queue preempts.  pftest deliberately faults
 * outside the map; the page-fault handler reports the address and panics,
 * which is the end of that boot.
 */

#include "console.h"
#include "trap.h"
#include "thread.h"
#include "ktest.h"

#define TESTTICKS	100

static volatile uint64_t ca, cb;

static void
worka(void)
{
	for(;;){
		ca++;
		__asm__ volatile("pause");
	}
}

static void
workb(void)
{
	for(;;){
		cb++;
		__asm__ volatile("pause");
	}
}

/* Waits n timer interrupts; returns how many actually passed. */
static uint64_t
wait(uint64_t n)
{
	uint64_t t0;

	t0 = ticks;
	while(ticks < t0 + n)
		__asm__ volatile("hlt");
	return ticks - t0;
}

void
kerneltest(void)
{
	uint64_t dt;
	int ok;

	__asm__ volatile("int $3");
	consprint("infernode/amd64: trap 3 handled\n");

	intr_enable();
	dt = wait(HZ / 5);
	consprint("infernode/amd64: timer advanced ");
	consprintdec(dt);
	consprint(" ticks\n");

	if(threadcreate("work-a", worka) == 0 ||
	   threadcreate("work-b", workb) == 0){
		consprint("infernode/amd64: kerneltest failed: threadcreate\n");
		return;
	}
	dt = wait(TESTTICKS);
	consprint("infernode/amd64: threads a ");
	consprintdec(ca);
	consprint(" b ");
	consprintdec(cb);
	consprint(" over ");
	consprintdec(dt);
	consprint(" ticks\n");

	ok = ca > 0 && cb > 0 && ca*4 > cb && cb*4 > ca;
	if(ok)
		consprint("infernode/amd64: kerneltest passed\n");
	else
		consprint("infernode/amd64: kerneltest failed\n");
}

void
pftest(void)
{
	consprint("infernode/amd64: pf test: writing 0xdead0000\n");
	*(volatile uint64_t*)(uintptr_t)0xdead0000 = 1;
	consprint("infernode/amd64: pf test failed: no fault\n");
}
