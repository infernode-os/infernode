/*
 * os/amd64/proctest.c -- os/port's processes at boot.
 *
 * This is the first time the kernel has real Procs: the process table
 * from xalloc, kernel stacks from the pool allocator, the scheduler's
 * setlabel/gotolabel switching, sleep/wakeup through Rendezes, and
 * qlocks.  Two kernel processes hand a Rendezvous back and forth; if the
 * scheduler, the error stack or the lock layer is wrong, the boot stops
 * here instead of printing the pass line.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

extern char	end[];		/* from kernel.ld: end of the kernel image */

static Rendez	rend1, rend2;
static QLock	ql;

static void
pta(void *a)
{
	USED(a);
	print("proctest: A up\n");
	qlock(&ql);
	print("proctest: A has qlock\n");
	qunlock(&ql);
	sleep(&rend1, return0, nil);
	print("proctest: A woke\n");
	wakeup(&rend2);
	print("proctest: proctest passed\n");
	conshalt();
}

static void
ptb(void *a)
{
	USED(a);
	print("proctest: B up\n");
	qlock(&ql);
	print("proctest: B has qlock\n");
	qunlock(&ql);
	wakeup(&rend1);
	sleep(&rend2, return0, nil);
	print("proctest: B woke\n");
}

void
proctest(void)
{
	Proc *p;
	uintptr base;
	unsigned long top;

	top = ramtop;
	base = ((uintptr)end + BY2PG-1) & ~(BY2PG-1);
	if(top <= base || top - base < 4*1024*1024){
		consprint("proctest: no memory above the kernel\n");
		return;
	}
	conf.base0 = base;
	conf.npage0 = (top - base) / BY2PG;
	conf.npage = conf.npage0;
	conf.nproc = 16;

	xinit();
	poolinit();
	procinit();

	p = newproc();
	if(p == nil){
		consprint("proctest: newproc failed\n");
		return;
	}
	up = p;
	m->ticks = 1;

	kproc("pt-a", pta, nil, 0);
	kproc("pt-b", ptb, nil, 0);

	/* never returns: the scheduler runs the two processes */
	schedinit();
}
