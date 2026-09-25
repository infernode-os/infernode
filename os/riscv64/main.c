/*
 * Kernel entry for the bare-metal RISC-V kernel.
 *
 * The boot sequence is ../arm64/main.c's, in the same dependency order
 * and for the reasons that file gives at each step; what it does not
 * carry over is arm64's battery of self-tests (probearch, probelibkern,
 * probealloc and the rest), which were how that kernel was brought up
 * one subsystem at a time. Here the subsystems are the ones already
 * proved there, compiled from the same files, and what is asserted at
 * boot is what is different: the trap path, SBI, the clock, the PLIC,
 * and the harts. The steps that are not tests but set state up --
 * the first process's namespace, the device resets, the console's
 * binding -- are kept, as bootproc() and bootcons().
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"
#include "kernel.h"

extern Dev	mntdevtab;
extern Dev	benchdevtab;
extern Dev	srvdevtab;
extern Dev	etherdevtab;
extern Dev	uartdevtab;
extern Dev	ipdevtab;

Conf conf;
uintptr	dtbptr;			/* l.S: the device tree the firmware passed */
ulong	boothartid;		/* l.S: the hart SBI started us on */
Mach	machs[MAXMACH];
struct Active active;

void	(*kproftick)(ulong);
void	(*proctrace)(Proc*, int, vlong);
void	(*screenputs)(char*, int);

static Proc mainproc;

int	boardharts(ulong*, int);	/* the board: hart ids that may run the kernel */

/*
 * Prove the trap path round trips before relying on it: an ebreak is
 * reported and stepped over by trap(), so reaching the next line means
 * save, dispatch and restore all worked.
 */
static void
checktraps(void)
{
	uartputstr("trap: testing the trap path with ebreak...");
	__asm__ volatile("ebreak");
	uartputstr("trap: returned, save/restore OK\n");
}

void
confinit(void)
{
	extern char end[];
	uintptr base, top;

	memset(&conf, 0, sizeof conf);

	conf.nmach = 1;
	conf.ialloc = 128*1024;
	conf.pipeqsize = 256*1024;

	base = PGROUND((uintptr)end);
	top = mmuramtop();

	conf.base0 = base;
	conf.npage0 = (top - base) / BY2PG;
	conf.npage = conf.npage0;

	/* see ../arm64/main.c: about five processes per MB, bounded */
	conf.nproc = 100 + (((conf.npage0 * BY2PG) >> 20) * 5);
	if(conf.nproc > 1000)
		conf.nproc = 1000;

	uartputstr("conf: ");
	uartputd(conf.npage0);
	uartputstr(" free pages (");
	uartputd((conf.npage0 * BY2PG) >> 20);
	uartputstr("MB) from ");
	uartputx(base);
	uartputstr(" to ");
	uartputx(top);
	uartputstr("\n");

	/*
	 * Keep the allocator off the device tree (INFR-458): split the
	 * bank around it if it lies inside. OpenSBI puts it near the top
	 * of RAM, which is inside.
	 */
	if(dtbptr >= base && dtbptr < top){
		uchar *h = (uchar*)dtbptr;
		u32int magic, dtbsize;
		uintptr dstart, dend;

		magic = h[0]<<24 | h[1]<<16 | h[2]<<8 | h[3];
		dtbsize = h[4]<<24 | h[5]<<16 | h[6]<<8 | h[7];
		if(magic == 0xd00dfeed && dtbsize >= 8 && dtbsize <= 4*1024*1024){
			dstart = dtbptr & ~(BY2PG-1);
			dend = PGROUND(dtbptr + dtbsize);
			if(dend > top)
				dend = top;
			conf.npage0 = (dstart - base) / BY2PG;
			conf.base1 = dend;
			conf.npage1 = (top - dend) / BY2PG;
			conf.npage = conf.npage0 + conf.npage1;
			uartputstr("conf: dtb at ");
			uartputx(dtbptr);
			uartputstr(" size ");
			uartputd(dtbsize);
			uartputstr(" -- reserved, bank split\n");
		}
	}
}

/*
 * The first process's namespace: a Proc to be `up', a Pgrp rooted at
 * the root device (through its own attach -- ../arm64/main.c,
 * probesysfile, says what devattach got wrong), an Fgrp and an Egrp.
 */
static void
bootproc(void)
{
	Proc *p;

	p = newproc();
	if(p == nil)
		panic("bootproc: newproc failed");
	kstrdup(&p->env->user, eve);
	p->env->pgrp = newpgrp();
	p->env->fgrp = newfgrp(nil);
	p->env->egrp = newegrp();
	if(p->env->pgrp == nil || p->env->fgrp == nil || p->env->egrp == nil)
		panic("bootproc: no namespace");
	up = p;

	{
		uchar mac[6];
		char buf[32];

		if(getmacaddr(mac) == 0){
			snprint(buf, sizeof buf,
				"%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux",
				mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
			ksetenv("ethermac", buf, 0);
		}
	}

	up->env->pgrp->slash = devtab[devno('/', 0)]->attach("");
	up->env->pgrp->dot = cclone(up->env->pgrp->slash);
	print("proc: first process up, namespace rooted\n");
}

/*
 * The devices' resets this kernel calls by hand, then every device's
 * init, then #c and #m on /dev. This kernel has no chandevreset();
 * ../arm64/main.c, probecons, says what went wrong each time one of
 * these was missed.
 */
static void
bootcons(void)
{
	int fd;

	if(mntdevtab.reset != nil)
		mntdevtab.reset();
	if(benchdevtab.reset != nil)
		benchdevtab.reset();
	if(srvdevtab.reset != nil)
		srvdevtab.reset();
	if(etherdevtab.reset != nil)
		etherdevtab.reset();
	if(uartdevtab.reset != nil)
		uartdevtab.reset();

	chandevinit();

	if(kbind("#c", "/dev", MREPL|MCREATE) < 0)
		panic("bootcons: cannot bind #c");
	kbind("#m", "/dev", MAFTER);

	fd = kopen("/dev/cons", OWRITE);
	if(fd < 0)
		panic("bootcons: cannot open /dev/cons");
	kwrite(fd, "cons: /dev/cons OK\n", 19);
	kclose(fd);
}

extern int	rootmaxq;
extern int	cflag;
extern void	loopbackmediumlink(void);
extern void	ethermediumlink(void);

#ifndef CFLAG
#define CFLAG 1
#endif

static void
startdis(void)
{
	cflag = CFLAG;

	print("\ndis:  handing control to the Dis VM\n");
	print("dis:  cflag=%d (%s)\n", cflag,
		cflag ? "JIT: compiling Dis to RISC-V" : "interpreter only");
	print("dis:  root filesystem: %d entries compiled into the image\n",
		rootmaxq);

	/* the IP stack, on the boot path: ../arm64/main.c, startdis */
	loopbackmediumlink();
	ethermediumlink();
	if(ipdevtab.reset != nil)
		ipdevtab.reset();

	kproc("display", displaywatch, nil, 0);
	kproc("dis", disinit, "/osinit.dis", KPDUPPG|KPDUPFDG|KPDUPENVG);
}

/*
 * Where a new kernel process begins: interrupts on, the function it
 * was made for, pexit when that returns -- and a name on the corpse if
 * it unwinds past its own error handlers (../arm64/main.c, linkproc).
 */
static void
linkproc(void)
{
	spllo();
	if(waserror()){
		char *e;

		e = "(no error string)";
		if(up->env != nil && up->env->errstr != nil && up->env->errstr[0] != '\0')
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
	p->sched.sp = (uintptr)p->kstack + KSTACK - 16;	/* the psABI's 16-byte sp */
	p->kpfun = func;
	p->arg = arg;
}

/*
 * Nothing to run: wait for an interrupt with interrupts OPEN, so that
 * whatever wakes the hart is also taken (../arm64/main.c, idlehands),
 * then back to the scheduler's splhi.
 */
void
idlehands(void)
{
	__asm__ volatile("csrsi sstatus, 2" ::: "memory");
	idlewfi();
	__asm__ volatile("csrci sstatus, 2" ::: "memory");
}

/*
 * The FP register file is live in any process that has run libinterp
 * (Dis has a REAL), and the scheduler's labels save only the integer
 * callee-saved registers: see ../arm64/main.c, procsave.
 */
void
procsave(Proc *p)
{
	FPsave(&p->fpsave);
}

void
procrestore(Proc *p)
{
	FPrestore(&p->fpsave);
}

/*
 * Secondary harts. SBI keeps them in the firmware until hart_start;
 * each arrives at secentry (l.S) with its Smpboot slot's address, takes
 * its stack and Mach from it, and comes here.
 */
typedef struct Smpboot Smpboot;
struct Smpboot {
	uvlong	sp;
	uvlong	mach;
	uvlong	entry;		/* nonzero until the hart acknowledges */
};
Smpboot smpboot[MAXMACH];

extern void secentry(void);

void
squidboy(void)
{
	trapinit();
	fpinit();
	m->ticks = 1;		/* nonzero: some code divides by ticks */
	m->proc = nil;

	intrsecinit();
	secclockinit();

	coherence();
	smpboot[m->machno].entry = 0;
	coherence();
	iprint("cpu%d: up (hart %lud)\n", m->machno, m->hartid);

	schedinit();
}

static void
launchsmp(void)
{
	ulong ids[MAXMACH*2];
	int i, n, nh, tries, r;
	uchar *stk;

	nh = boardharts(ids, nelem(ids));
	conf.nmach = 1;
	n = 1;
	for(i = 0; i < nh && n < MAXMACH; i++){
		if(ids[i] == boothartid)
			continue;
		stk = malloc(8192);
		if(stk == nil)
			panic("launchsmp: no stack for cpu%d", n);
		machs[n].machno = n;
		machs[n].hartid = ids[i];
		smpboot[n].sp = (uvlong)(uintptr)(stk + 8192);
		smpboot[n].mach = (uvlong)(uintptr)MACHP(n);
		smpboot[n].entry = (uvlong)(uintptr)secentry;
		coherence();
		n++;
	}
	/* ilock's "nmach<2" shortcut must be gone before a second hart runs */
	conf.nmach = n;
	for(i = 1; i < n; i++){
		r = sbihartstart(machs[i].hartid, (uintptr)secentry, (uintptr)&smpboot[i]);
		if(r != 0)
			print("sbi: hart_start hart %lud refused (%d)\n", machs[i].hartid, r);
	}
	for(tries = 0; tries < 5000; tries++){
		for(i = 1; i < n; i++)
			if(smpboot[i].entry != 0)
				break;
		if(i == n)
			break;
		microdelay(1000);
	}
	for(i = 1; i < n; i++){
		if(smpboot[i].entry == 0)
			active.machs |= 1<<i;
		else
			print("cpu%d (hart %lud): did not answer\n", i, machs[i].hartid);
	}
	for(i = 0, r = 0; i < MAXMACH; i++)
		if(active.machs & (1<<i))
			r++;
	print("smp:  %d hart%s running\n", r, r == 1 ? "" : "s");
}

/*
 * ready() made something runnable: wake any hart asleep in wfi, with an
 * IPI through SBI. A spurious wakeup is the idle loop's normal diet.
 */
void
idlewake(void)
{
	ulong mask;
	int i;

	mask = 0;
	for(i = 0; i < conf.nmach; i++)
		if(i != m->machno && (active.machs & (1<<i)) && machs[i].hartid < 64)
			mask |= 1UL << machs[i].hartid;
	if(mask != 0)
		sbisendipi(mask, 0);
}

void
kmain(void)
{
	m->proc = &mainproc;
	m->machno = 0;
	m->hartid = boothartid;

	uartinit();

	uartputstr("\nInferNode bare-metal (");
	uartputstr(boardname());
	uartputstr(")\n");
	uartputstr("  hart:            ");
	uartputd(boothartid);
	uartputstr("\n  console:         ");
	uartputstr(uartdescribe());
	uartputstr("\n  firmware:        ");
	uartputstr(sbidescribe());
	uartputstr("\n  types:           ");
	uartputstr(typecheck() ? "riscv64 u.h OK (LP64, stdarg)" : "TYPE FOUNDATION BROKEN");
	uartputstr("\n");

	trapinit();
	uartputstr("  vectors:         stvec installed\n\n");
	checktraps();

	serialrecover();
	boardprobe();
	boardbootwatchdog();

	mmuinit();
	boardlockon();
	uartlockon();
	uartputstr("mmu:  off (Bare: physical addressing), ramtop ");
	uartputx(mmuramtop());
	uartputstr("\n");

	confinit();
	xinit();
	poolinit();
	printinit();

	intrinit();
	clockinit();

	serwrite = uartputs;
	kstrdup(&eve, "inferno");
	kstrdup(&sysname, "infernode");
	quotefmtinstall();
	procinit();
	boardioprobe();

	bootproc();
	bootcons();

	{
		ulong mem;

		mem = (ulong)conf.npage * BY2PG;
		poolsize(mainmem, mem/8, 0);
		poolsize(heapmem, mem/4, 0);
		poolsize(imagmem, mem/8, 0);
	}

	boardintrprobe();
	boardfbprobe();
	boarddevprobe();

	kbind("#S", "/dev", MAFTER);
	kbind("#B", "/dev", MAFTER);
	kbind("#b", "/dev", MAFTER);

	print("clock: %llud Hz timebase, %d Hz tick\n", clockfreq(), HZ);
	uartputstr("\nboot OK\n");

	active.machs = 1;
	startdis();
	launchsmp();

	up = nil;
	spllo();
	schedinit();

	for(;;)
		idlewfi();
}
