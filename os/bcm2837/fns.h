/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
void	uartputs(char*);
void	uartputx(u64int);
void	uartputd(u64int);

/* gpio.c */
void	gpiofunc(int, int);
void	gpiopull(int, int);
void	gpioout(int, int);
int	gpioin(int);
int	gpiogetfunc(int);

/* mailbox.c */
int	mboxprop(u32int, u32int*, int, int);
int	mboxfballoc(u32int, u32int, u32int, Fbinfo*);

/* fb.c */
int	fbinit(Fbinfo*);
void	fbfill(Fbinfo*, u32int);
void	fbrect(Fbinfo*, int, int, int, int, u32int);

/* arch.S -- AArch64 primitives that cannot be written in C */
ulong	_tas(ulong*);
void	coherence(void);
int	setlabel(Label*);
void	gotolabel(Label*);
void	cacheiflush(void*, ulong);

/* arch.c -- interrupt priority level */
ulong	splhi(void);
ulong	spllo(void);
void	splx(ulong);
void	splxpc(ulong);
int	islo(void);

/*
 * os/port calls getcallerpc(&firstarg) to record which caller took a
 * lock.  Upstream implements it by walking back from the argument's
 * address, which assumes a stack-based calling convention.  AAPCS64
 * passes arguments in registers, so that would read garbage; the
 * compiler builtin is both correct and cheaper.  It is a macro rather
 * than a function so the builtin resolves in the CALLER's frame.
 */
#define getcallerpc(x)	((ulong)(uintptr)__builtin_return_address(0))

/* print.c -- the seam libkern's fmt engine expects from the kernel */
int	print(char*, ...);
void	panic(char*, ...);
void	ixsummary(void);
void	debugkey(int, char*, void(*)(void), int);

/* lock.c -- stands in for os/port/taslock.c until proc.c exists */
void	lock(Lock*);
void	unlock(Lock*);
int	canlock(Lock*);
void	ilock(Lock*);
void	iunlock(Lock*);

/* libkern, once an allocator exists */
char*	smprint(char*, ...);
char*	strdup(char*);

/* os/port/allocb.c */
Block*	allocb(int);
Block*	iallocb(int);
void	freeb(Block*);
void	checkb(Block*, char*);
void	iallocsummary(void);

/* os/port/alloc.c */
void	poolinit(void);
void*	malloc(ulong);
void	free(void*);
void	poolsummary(void);
void	setmalloctag(void*, ulong);
void	setrealloctag(void*, ulong);
ulong	getmalloctag(void*);
ulong	getrealloctag(void*);
void*	smalloc(ulong);
ulong	msize(void*);
void*	mallocz(ulong, int);
void	poolimmutable(void*);
void	poolmutable(void*);

/* console + panic support os/port expects */
void	putstrn(char*, int);
void	exhausted(char*);
void	setpanic(void);
int	return0(void*);
void	tsleep(Rendez*, int(*)(void*), void*, int);

/* os/port/xalloc.c */
void	xinit(void);
void*	xalloc(ulong);
void*	xspanalloc(ulong, int, ulong);
void	xfree(void*);
void	xhole(uintptr, uintptr);
int	xmerge(void*, void*);
void	xsummary(void);

/* clock.c */
void	clockinit(void);
u64int	clockcount(void);
u64int	clockfreq(void);
u64int	clockticks(void);
u64int	systimer(void);
void	microdelay(u64int);
int	clockintr(void);
int	irqdispatch(void);
void	intrenable(void);
void	intrdisable(void);
int	intrenabled(void);

/* mmu.c */
void	mmuinit(void);
void	mmuenable(void);
int	mmuon(void);
int	mmucaches(void);
uintptr	mmuramtop(void);
uintptr	mmul1(void);
uintptr	mmumapped(void);
u64int	mmutcr(void);
u64int	mmumair(void);

/* trap.c */
void	trap(Ureg*);
void	dumpureg(Ureg*);

/* vectors.S */
void	trapinit(void);

/* typecheck.c */
int	typecheck(void);

/* main.c */
void	kmain(void);
