/*
 * os/amd64/port.c -- the globals os/port expects a platform to define.
 *
 * One processor, so one Mach, and `m` points at it.  The values here
 * are the ones a single-CPU kernel with a flat identity map can state
 * now; allocation, the clock and the process table fill in the rest as
 * those files arrive.  conf.base0/npage0 describe the free bank the
 * caller measured: above the kernel image and below any reserved
 * region, so xalloc never hands out the image itself.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

/*
 * Optional hooks os/port declares and a platform may leave nil.  The
 * profiler, the scheduler trace and the software screen have no users
 * yet.
 */
void	(*kproftick)(ulong);
void	(*proctrace)(Proc*, int, vlong);
void	(*screenputs)(char*, int);

/*
 * A new kernel process enters here on its own stack.  The scheduler's
 * gotolabel has just restored its Label and set up, so this is an
 * ordinary C frame.
 */
static void
linkproc(void)
{
	/*
	 * The outer handler every kernel process needs: a body that calls
	 * error() without a handler of its own unwinds to here.  Name the
	 * process rather than the trampoline.
	 */
	if(waserror()){
		char *e;

		e = "(no error string)";
		if(up->env != nil && up->env->errstr != nil &&
		   up->env->errstr[0] != '\0')
			e = up->env->errstr;
		print("linkproc: error() underflow in %lud:%s (kpfun %#p): %s\n",
			up->pid, up->text, up->kpfun, e);
	}else
		(*up->kpfun)(up->arg);
	pexit("end proc", 1);
}

void
kprocchild(Proc *p, void (*func)(void*), void *arg)
{
	p->sched.pc = (uintptr)linkproc;
	p->sched.sp = (uintptr)p->kstack + KSTACK - 8;
	memset(p->sched.regs, 0, sizeof(p->sched.regs));
	p->kpfun = func;
	p->arg = arg;
}

/* no x87 state is live yet: the kernel is -mno-sse and runs no VM */
void
procsave(Proc *p)
{
	USED(p);
}

void
procrestore(Proc *p)
{
	USED(p);
}

void
fpinit(void)
{
}

void
fpoff(void)
{
}

/*
 * The clock's contribution.  Ticks are counted so sleep and the
 * scheduler have a clock; preemption arrives with portclock.c.
 */
void
hzclock(Ureg *ur)
{
	USED(ur);
	m->ticks++;
}

Conf	conf;
Mach	machs[MAXMACH];
Mach	*m;
struct Active active;
unsigned long ramtop;

void
portinit(uint64_t membase, uint64_t memsize)
{
	m = &machs[0];
	m->machno = 0;

	ramtop = membase + memsize;
	conf.nmach = 1;
	conf.nproc = 32;
	conf.base0 = membase;
	conf.npage0 = memsize / BY2PG;
	conf.npage = conf.npage0;
	conf.ialloc = 4096;
	conf.pipeqsize = 8 * 1024;

	consprint("infernode/amd64: port: ");
	consprintdec(conf.nmach);
	consprint(" cpu, ");
	consprintdec(conf.npage);
	consprint(" pages\n");
}
