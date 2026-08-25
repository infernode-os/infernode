/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
int	uartgetc(void);
int	hwrandom(uchar*, int);
void	uartputstr(char*);
void	uartputx(u64int);
void	uartputd(u64int);

/*
 * board.c -- the four things a platform supplies to the shared kmain.
 *
 * Everything else in this header is common to any AArch64 board. These
 * are the seams where "which machine is this" is allowed to matter, and
 * keeping them few is the point: a fifth hook should be an argument for
 * moving the code into os/arm64, not for widening the interface.
 *
 * boardname       banner text, so the log says which port produced it
 * boardprobe      earliest platform bring-up, before the MMU. An
 *                 interrupt controller belongs here -- clockinit runs
 *                 later and expects one to exist.
 * boardioprobe    platform I/O self-tests, after the process table
 * boardclockcheck cross-check CNTFRQ_EL0 against an independent clock.
 *                 CNTFRQ is a value firmware writes rather than
 *                 something hardware derives, so it can be wrong, and a
 *                 wrong one never presents as a clock bug.
 * boardfbprobe    framebuffer bring-up, last, once everything it needs
 *                 is up
 */
char*	boardname(void);
void	boardprobe(void);
void	boardioprobe(void);
void	boardclockcheck(void);
void	boardfbprobe(void);

/* arch.S -- AArch64 primitives that cannot be written in C */
void	coherence(void);
void	fpinit(void);
void	cacheiflush(void*, ulong);
void	cachedwbinvse(void*, int);
void	cachedwbse(void*, int);

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
void	microdelay(int);
int	clockintr(Ureg*);
int	irqdispatch(Ureg*);
extern int irqorphan;
void	intrdump(void);
int	intrpending(void);
int	getmacaddr(uchar*);
extern ulong nspurious;
/*
 * intr.c -- the board's interrupt controller.
 *
 * intrenable() registers a handler for one source. It does NOT mean
 * "unmask interrupts on this CPU"; that is spllo(), and this name
 * meant it here once, which is exactly the confusion worth naming.
 */
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrinit(void);
void	armtimerset(int);
void	usbdwclink(void);
int	intrgpu(Ureg*);

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

/*
 * The device tree pointer the firmware passed in x0.
 *
 * l.S parks it as its first instruction and stores it once .bss is
 * clear. Both boot protocols supply one -- the Raspberry Pi firmware
 * passes a DTB as well -- and this port does not parse it: bcm2837
 * gets its memory layout from the VideoCore mailbox. Kept because
 * discarding the pointer is a latent gap, and recovering it later
 * would mean touching the reset path.
 */
extern uintptr	dtbptr;

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
void	procrestore(Proc*);
void	confinit(void);
void	kmapinval(void);
void	hzclock(Ureg*);
extern int	rootosinitlen;
void	dumpstack(void);
void	kprocchild(Proc*, void(*)(void*), void*);

/*
 * waserror() had no bound. up->errlab holds NERR entries; once nerrlab
 * reaches NERR the setlabel() below writes a whole Label -- sp, pc and
 * eleven callee-saved registers -- past the end of the array and into
 * the rest of Proc, and the matching nexterror() then gotolabel()s
 * through whatever it finds. That sets sp and pc to arbitrary values,
 * which is not a crash so much as a random jump.
 *
 * errlabcheck() makes the overflow say so. It has to be a separate
 * call rather than a test inside the expression because setlabel()
 * must be reached from the CALLER's frame -- that is the frame
 * gotolabel() will resume into.
 */
#define	waserror()	(errlabcheck(), up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#include "../port/portfns.h"
void	boardreboot(void);
