/*
 * os/amd64/thread.c -- a round-robin run queue.
 *
 * The boot processor's first thread is main itself; the scheduler adopts
 * the frame the first timer interrupt leaves.  New threads are built
 * bottom-up: a trap frame at the top of a stack with RIP at the entry
 * point and RFLAGS.IF set, so the common interrupt return path starts
 * them with no special case.
 *
 * There is no freelist, no exit and no priority: this is the minimum that
 * makes more than one thing run, which is what os/port's proc layer will
 * sit on.
 */

#include <string.h>
#include "trap.h"
#include "thread.h"

#define NTHREAD		4
#define TSTACKSIZE	(16 * 1024)

static Thread threads[NTHREAD];
static uint8_t tstacks[NTHREAD][TSTACKSIZE] __attribute__((aligned(16)));
static int nthread;
static int curidx;
static Thread *cur;

void
threadsinit(void)
{
	memset(threads, 0, sizeof(threads));
	nthread = 1;
	curidx = 0;
	cur = &threads[0];
	cur->name = "main";
	cur->state = ThrRun;
}

Thread*
threadcreate(char *name, void (*entry)(void))
{
	Trapframe *f;
	Thread *t;
	uint8_t *top;
	uint64_t flags;
	int slot;

	flags = intr_disable();
	if(nthread >= NTHREAD){
		intr_restore(flags);
		return 0;
	}
	slot = nthread;
	t = &threads[slot];
	memset(t, 0, sizeof(*t));
	t->name = name;
	t->state = ThrRun;

	/*
	 * The frame ends at stack_top-8, so after iretq the entry point is
	 * entered with rsp%16 == 8, the alignment a C function expects
	 * just after a call.  The eight bytes there read as its return
	 * address: a thread that returns faults at 0 rather than
	 * wandering.
	 */
	top = tstacks[slot] + TSTACKSIZE;
	top = (uint8_t*)((uintptr_t)top & ~(uintptr_t)15);
	top -= 8;
	*(uint64_t*)top = 0;
	f = (Trapframe*)(top - sizeof(Trapframe));
	memset(f, 0, sizeof(*f));
	f->rip = (uint64_t)(uintptr_t)entry;
	f->cs = KCS;
	f->rflags = 0x202;		/* IF: interrupts on when it starts */
	f->rsp = (uint64_t)(uintptr_t)top;
	f->ss = KDS;
	t->sp = (uint64_t)(uintptr_t)f;

	nthread++;
	intr_restore(flags);
	return t;
}

Trapframe*
threadsched(Trapframe *f)
{
	Thread *next;
	int i, k;

	cur->sp = (uint64_t)(uintptr_t)f;
	k = curidx;
	for(i = 1; i <= nthread; i++){
		k = (curidx + i) % nthread;
		if(threads[k].state == ThrRun)
			break;
	}
	if(i > nthread)
		return f;
	curidx = k;
	next = &threads[k];
	cur = next;
	next->runs++;
	return (Trapframe*)(uintptr_t)next->sp;
}
