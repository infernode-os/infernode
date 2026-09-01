/*
 * Platform data types for the bare-metal BCM2837 kernel.
 *
 * Structured the way every upstream os/ port structures its dat.h: the
 * machine-specific types first, then ../port/portdat.h, then Mach --
 * which has to come last because it holds a Proc*, and Proc is defined
 * by portdat.h.
 *
 * The integer vocabulary comes from Inferno/arm64/include/u.h. The
 * tree's own include/lib9.h is not usable here: it pulls in stdio.h,
 * setjmp.h and time.h, none of which exist with no host OS underneath.
 *
 * Following Plan 9 convention, this header does NOT include u.h: every
 * .c includes u.h first and dat.h after.  Upstream os/port is written
 * that way throughout, so matching it keeps imported files diff-able
 * against their originals -- and u.h has no include guard, exactly
 * because it is expected to be included once, first, by hand.
 */

typedef struct Conf	Conf;
typedef struct FPenv	FPenv;
typedef struct FPU	FPU;
typedef struct Label	Label;
typedef struct Lock	Lock;
typedef struct Mach	Mach;
typedef struct Ureg	Ureg;

typedef ulong		Instr;

/*
 * pool.h is NOT included here: ../port/portdat.h includes <pool.h>
 * itself, and pool.h has no include guard, so a second inclusion is a
 * redefinition error rather than a no-op.
 */

/*
 * A saved execution point, for the scheduler and for error unwinding.
 *
 * sp, pc, AND the callee-saved registers x19-x29.
 *
 * Saving only sp and pc -- which is what upstream's 32-bit ARM ports do
 * -- is wrong under a modern compiler, and wrong in a way that produces
 * corruption rather than a crash. gotolabel is a longjmp: it re-enters
 * a frame from deeper in the call chain, SKIPPING every intervening
 * epilogue. Callee-saved registers are callee-saved precisely because
 * those epilogues restore them, so bypassing the epilogues leaves them
 * holding whatever the abandoned callees left behind.
 *
 * Upstream survives this because the Plan 9 compiler keeps locals in
 * memory. clang at -O2 does not: os/port/dev.c's devwalk kept its
 * Walkqid* in x19 across waserror(), and its error handler then called
 * free() on whatever x19 happened to contain. The pool allocator
 * rejected the pointer, which is the good outcome -- the bad one is a
 * pointer that happens to look valid.
 *
 * Order here must match arch.S: sp at 0, pc at 8, regs at 16.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;
	uintptr	regs[11];	/* x19-x29 */
};

/*
 * A spin lock.
 *
 * key is the word _tas operates on and is ulong to match upstream's
 * portfns.h declaration of ulong _tas(ulong*).  sr holds the interrupt
 * level saved by ilock so iunlock can restore exactly what was found
 * rather than assuming.  pc records who took it, which is what makes a
 * stuck lock diagnosable instead of a hang.
 *
 * Named members rather than the Plan 9 anonymous embedding used
 * upstream -- see os/bcm2837/README.md for why -fms-extensions is not a
 * safe substitute.
 */
struct Lock
{
	ulong	key;
	ulong	sr;
	uintptr	pc;
	int	pri;
};

/*
 * Per-thread floating point state, held in Osenv.
 *
 * This must be big enough for everything FPsave() writes into it --
 * os/port/dis.c does FPsave(&up->env->fpu) with exactly this struct.
 *
 * An earlier version defined it as just FPCR and FPSR, on the reasoning
 * that AArch64 has real hardware FP and does not need the emulated
 * register file the 32-bit ARM ports carry here. That was wrong in the
 * worst available way: FPsave still wrote all 32 V registers, 520 bytes
 * into an 8-byte field, straight through the rest of Osenv. The kernel
 * did not fault -- it silently corrupted the process environment and
 * then stopped, with no indication that floating point was involved.
 *
 * The layout is fixed by arch.S: 32 128-bit V registers, then FPCR at
 * offset 512 and FPSR at 516. Do not reorder without changing both.
 */
struct FPenv
{
	uvlong	regs[64];	/* 32 x 128-bit V registers */
	u32int	fpcr;		/* control: rounding and trap enables */
	u32int	fpsr;		/* status: accrued exception flags */
};

/*
 * Saved FP/SIMD state, per process.
 *
 * AArch64 has 32 128-bit V registers plus FPCR and FPSR.  Nothing saves
 * or restores this yet -- the kernel is built -mgeneral-regs-only
 * precisely so no interrupt path touches FP state we are not preserving
 * -- but Proc embeds an FPU, so the shape has to be right now or every
 * Proc changes size later.
 */
/*
 * Per-process FP state machine, as os/port/proc.c expects. Nothing
 * switches FP state yet -- the kernel is -mgeneral-regs-only -- so every
 * Proc stays at FPINIT, but proc.c assigns the value so it must exist.
 */
enum
{
	FPINIT,
	FPACTIVE,
	FPINACTIVE,
};

struct FPU
{
	uvlong	regs[64];	/* 32 x 128-bit V registers */
	u32int	fpcr;
	u32int	fpsr;
};

/*
 * Machine configuration, filled in at boot.  os/port/xalloc.c reads the
 * memory bank fields directly to decide what it may hand out.
 *
 * These are ulong, matching upstream, which is correct here only
 * because ulong is 64 bits: base0/base1 hold addresses.
 */
struct Conf
{
	ulong	nmach;		/* processors */
	ulong	nproc;		/* processes */
	ulong	npage0;		/* pages in bank 0 */
	ulong	npage1;		/* pages in bank 1 */
	ulong	npage;		/* total physical pages */
	ulong	base0;		/* base of bank 0 */
	ulong	base1;		/* base of bank 1 */
	ulong	ialloc;		/* max interrupt-time allocation, bytes */
	ulong	pipeqsize;	/* size in bytes of pipe queues */
	int	nuart;		/* number of uart devices */
	ulong	monitor;	/* has a display? */
	ulong	copymode;	/* 0 copy-on-write, 1 copy-on-reference */
};

#include "../port/portdat.h"

/*
 * Per-processor state.  Must follow portdat.h because it holds a Proc*.
 *
 * The 32-bit ARM ports carry separate fiq/irq/abt/und stacks here,
 * because AArch32 gives each exception mode its own banked stack
 * pointer.  AArch64 does not work that way: there is one vector table
 * and exceptions taken to EL1 use SP_EL1, so those fields have no
 * meaning here and are gone.
 */
struct Mach
{
	int		machno;		/* physical id of this processor */
	uintptr		splpc;		/* pc of the last caller to splhi */
	Proc*		proc;		/* current process on this processor */
	Label		sched;		/* scheduler's saved context */
	Lock		alarmlock;	/* access to the alarm list */
	void*		alarm;		/* alarms bound to this clock */
	ulong		ticks;		/* of the clock, since boot */
	ulong		cpuhz;
	int		nrdy;
	int		stack[1];
};

/*
 * Which processors are up, and whether we are shutting down.
 *
 * os/port/portclock.c's hzclock() returns early unless this
 * processor's bit is set, so nothing on the clock -- including
 * checkalarms() and preemption -- runs until boot sets it. That guard
 * is the point: it stops the clock interrupt from scheduling or
 * expiring alarms before there is anything safe to schedule.
 *
 * Named Lock rather than the Plan 9 anonymous embed, as everywhere else
 * in this port.
 */
extern struct Active
{
	Lock	l;
	int	machs;			/* bitmap of active CPUs */
	int	exiting;		/* shutdown */
	int	ispanic;		/* shutdown in response to a panic */
	int	thunderbirdsarego;	/* secondaries may enter schedinit */
} active;

/*
 * The per-core pointer, and the convention that carries SMP.
 *
 * m lives in x28, reserved kernel-wide by -ffixed-x28: each core's
 * boot path loads its own Mach* there before running any C, exception
 * entry saves and restores it with the rest of the frame, and C never
 * assigns it -- so every core that executes kernel code sees its own
 * Mach through the same name, with no addressing, no lock, and no
 * chance of reading another core's.
 *
 * up is not a variable at all: it is this core's Mach's proc field,
 * which makes "up = p" per-core automatically and leaves nothing to
 * keep in sync. The name is safe to define away -- no struct field or
 * local in the tree is called up; the build would say so if one ever
 * appeared.
 *
 * The JIT was audited for x28 before this convention was adopted:
 * generated code touches only x0-x5, x20-x22 and x30. Any future code
 * generator must keep to that.
 */
register Mach	*m asm("x28");

/*
 * up reads x28 through the assembler, not through the identifier m --
 * because locals named m are everywhere in inherited code, they
 * legally shadow the register variable, and a macro that mentioned m
 * by name dereferenced whatever integer the nearest scope kept under
 * that letter. The first build found that in devsd.c inside
 * waserror(), as "member reference type 'long' is not a pointer".
 */
static inline Proc**
_upaddr(void)
{
	Mach *mm;

	__asm__("mov %0, x28" : "=r"(mm));
	return &mm->proc;
}
#define	up	(*_upaddr())

extern Mach	machs[];
#define	MACHP(n)	(&machs[n])

/*
 * A framebuffer as the VideoCore firmware handed it back.  pitch is the
 * byte stride of a row and is NOT necessarily width*bytes-per-pixel --
 * the firmware pads, and assuming otherwise skews the image.
 */
typedef struct Fbinfo Fbinfo;

struct Fbinfo
{
	u32int	disp;		/* which display the firmware put it on */
	uintptr	base;
	u32int	size;
	u32int	pitch;
	u32int	width;
	u32int	height;
	u32int	depth;
};
