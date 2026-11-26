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
#include "ureg.h"
#include "port.h"

extern char	end[];		/* from kernel.ld */

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
	spllo();
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
	p->fpsave = initfp;
	p->fpstate = FPINIT;
	p->kpfun = func;
	p->arg = arg;
}

/*
 * libinterp compiles Dis REALs to SSE instructions, so a process's
 * XMM/x87/MXCSR state is part of what a context switch must preserve.
 * The scheduler calls these around setlabel/gotolabel; fp.S does the
 * FXSAVE64/FXRSTOR64, through an aligned stack slot because a
 * Prog's Osenv is a malloc'd block of no particular alignment.
 */
void
procsave(Proc *p)
{
	FPsave(&p->fpsave);
	p->fpstate = FPACTIVE;
}

void
procrestore(Proc *p)
{
	/*
	 * A process that has never run has no state of its own; give it
	 * the architectural default rather than whatever the scheduler
	 * happened to have in the registers.
	 */
	if(p->fpstate == FPINIT){
		p->fpsave = initfp;
		p->fpstate = FPACTIVE;
	}
	FPrestore(&p->fpsave);
}

/*
 * fpoff is for a port with lazy FP switching (CR0.TS).  This one saves
 * and restores eagerly at every switch, so there is nothing to turn
 * off; the name has to exist because os/port/devcons.c offers it to a
 * process as #c/consctl "fpoff".
 */
void
fpoff(void)
{
}


/*
 * The trap has a Trapframe; os/port asks for a Ureg.  timerintr() walks
 * the timer queue for this processor and runs the periodic clock Timer
 * that logs the tick -- which is what calls hzclock(), preemption and
 * expired sleeps included.
 */
void
portclocktick(uint64_t pc)
{
	Ureg u;

	u.pc = (uintptr)pc;
	u.sp = 0;
	timerintr(&u, fastticks(nil));
}

int
portactive(void)
{
	return up != nil;
}

/*
 * The allocators and the process table, in the order the native kernel
 * brings them up: xinit over [end, ramtop), malloc's pools on top, then
 * procinit's arena out of xalloc.  Leaves up as a new boot process so
 * kproc() has a creator.
 */
int
portprocinit(void)
{
	Proc *p;
	uintptr base;
	ulong top;

	top = ramtop;
	/*
	 * boot.S maps only the first GiB.  A loader that reports more RAM
	 * must not make xinit hand out pages above the mapped range.
	 */
	if(top > 0x40000000UL)
		top = 0x40000000UL;
	base = ((uintptr)end + BY2PG-1) & ~(BY2PG-1);
	if(top <= base || top - base < 4*1024*1024)
		return -1;
	conf.base0 = base;
	conf.npage0 = (top - base) / BY2PG;
	conf.npage = conf.npage0;
	conf.nproc = 16;

	xinit();
	poolinit();
	printinit();		/* the console input queue, before #c is used */
	timersinit();
	procinit();

	/* the host owner and this machine's name, for devdir and #c */
	kstrdup(&eve, "inferno");
	kstrdup(&sysname, "infernode");

	p = newproc();
	if(p == nil)
		return -1;
	up = p;
	kstrdup(&up->env->user, eve);	/* the boot process is the host owner */
	m->ticks = 1;
	return 0;
}

Conf	conf;
FPU	initfp;		/* fpinit in arch.S/fp.S records the reset state here */
Mach	machs[MAXMACH];
Mach	*m;
struct Active active;
unsigned long ramtop;

/*
 * consoleprint is the console's own switch.  cflag, strictlink and
 * keepbroken belong to libinterp (os/port/dis.c, libinterp/link.c) and
 * are defined there; the port must not define them a second time.
 */
int	consoleprint;

void
portinit(uint64_t membase, uint64_t memsize)
{
	m = &machs[0];
	m->machno = 0;

	ramtop = membase + memsize;
	fpinit();		/* before any process can be switched to */
	clockinit();
	serwrite = conswrite;
	active.machs = 1;
	conf.nmach = 1;
	conf.nproc = 32;
	conf.base0 = membase;
	conf.npage0 = memsize / BY2PG;
	conf.npage = conf.npage0;
	/*
	 * What interrupt-time allocation may hold, in bytes of block
	 * (BALLOC, so the queue's own limit is in the same currency).
	 * It was 4K while nothing allocated at interrupt time; the
	 * console's receive poller is the first such user, and one byte
	 * of type-ahead costs a whole Block: 4K is about twenty
	 * characters, and a command line is longer than that.  The other
	 * native ports use 128K, which is roughly seven hundred.
	 */
	conf.ialloc = 128*1024;
	conf.pipeqsize = 8 * 1024;

	consprint("infernode/amd64: port: ");
	consprintdec(conf.nmach);
	consprint(" cpu, ");
	consprintdec(conf.npage);
	consprint(" pages\n");
}
