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
 * A saved execution point, for the scheduler.
 *
 * Only sp and pc: gotolabel restores the stack pointer and jumps, and
 * the callee-saved registers survive because setlabel's caller saved
 * them on entry per AAPCS64.  This is NOT jmp_buf (see u.h), which has
 * to save far more because it can be longjmp'd to from anywhere.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;
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
 * The 32-bit ARM ports carry an emulated-FP register file here because
 * they had no hardware FPU. AArch64 mandates FP/SIMD, so this is just
 * the two control registers; the register file itself lives in FPU
 * below, saved per process rather than per thread.
 */
struct FPenv
{
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

extern Mach	*m;
extern Proc	*up;
extern Mach	mach0;

/*
 * Single core for now.  When the secondary cores are released from the
 * park loop in l.S this becomes an array indexed by machno.
 */
#define	MACHP(n)	((n) == 0 ? &mach0 : (Mach*)0)

/*
 * A framebuffer as the VideoCore firmware handed it back.  pitch is the
 * byte stride of a row and is NOT necessarily width*bytes-per-pixel --
 * the firmware pads, and assuming otherwise skews the image.
 */
typedef struct Fbinfo Fbinfo;

struct Fbinfo
{
	uintptr	base;
	u32int	size;
	u32int	pitch;
	u32int	width;
	u32int	height;
	u32int	depth;
};
