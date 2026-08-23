/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
void	uartputstr(char*);
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
void	coherence(void);
void	cacheiflush(void*, ulong);

/* arch.c -- interrupt priority level */

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
void	ixsummary(void);

/* lock.c -- stands in for os/port/taslock.c until proc.c exists */

/* libkern, once an allocator exists */

/* os/port/allocb.c */

/* os/port/alloc.c */

/* console + panic support os/port expects */

/* os/port/xalloc.c */
void*	xspanalloc(ulong, int, ulong);
void	xhole(uintptr, uintptr);
int	xmerge(void*, void*);

/* clock.c */
void	clockinit(void);
u64int	clockcount(void);
u64int	clockfreq(void);
u64int	clockticks(void);
u64int	systimer(void);
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

/*
 * The portable kernel's function declarations. Upstream's platform
 * fns.h ends this way; everything above is the machine-specific half
 * that os/port expects each port to supply.
 */
/*
 * The error-unwinding macro os/port is written against. It pushes a
 * Label onto the current process's error stack and returns 0; a later
 * error() gotolabels back to it, so it appears to return 1. This is
 * setlabel/gotolabel doing for error handling what sched() does for
 * context switching.
 */
/*
 * Console output mirror.
 *
 * devcons.c calls this, when non-nil, to send console text somewhere in
 * addition to the serial line -- a framebuffer, typically. Declared
 * extern here and defined once in main.c: upstream's platform fns.h
 * writes it without extern, which makes it a tentative definition and a
 * duplicate symbol under -fno-common, the same way portfns.h's
 * kproftick was.
 *
 * Left nil for now. Pointing it at a framebuffer text renderer is what
 * would put console output on the 7in panel.
 */
void	setpanic(void);
extern void	(*screenputs)(char*, int);

/* platform hooks os/port/proc.c calls */
void	idlehands(void);
void	procsave(Proc*);
void	confinit(void);
void	dumpstack(void);
void	kprocchild(Proc*, void(*)(void*), void*);

#define	waserror()	(up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#include "../port/portfns.h"
