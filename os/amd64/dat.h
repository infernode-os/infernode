/*
 * Platform data types for the native amd64 kernel.
 *
 * Structured like ../arm64/dat.h, which explains the shape at length:
 * machine types first, then ../port/portdat.h, then Mach, which holds a
 * Proc*.  Every .c includes u.h first and this after.
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
 * A saved execution point, for the scheduler and for error unwinding:
 * sp, the resume pc, and every callee-saved register (rbx, rbp,
 * r12-r15).  Saving only sp and pc is wrong under an optimising
 * compiler: gotolabel skips the epilogues that would have restored the
 * callee-saved registers.  Order must match arch.S.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;
	uintptr	regs[6];	/* rbx, rbp, r12, r13, r14, r15 */
};

/* A spin lock; _tas works on key.  sr holds the flags splhi saved. */
struct Lock
{
	ulong	key;
	ulong	sr;
	uintptr	pc;
	int	pri;
	void*	p;	/* the Proc that took it last: lockloop says what it is doing */
};

/*
 * Floating point state, as FXSAVE64 writes it: x87 (FCW, FSW, FTW, the
 * data pointers, ST0-ST7) followed by MXCSR, MXCSR_MASK and XMM0-XMM15
 * -- 512 bytes in all.
 *
 * The layout is the hardware's, not ours: fp.S hands the address
 * straight to FXSAVE64/FXRSTOR64, through an aligned stack slot,
 * because an Osenv's FPenv sits at `malloc(sizeof(Prog)+sizeof(Osenv))`
 * -- a block aligned for malloc's largest type, which is not 16 bytes,
 * at an offset that is not either.
 *
 * Deliberately NOT declared 16-byte aligned.  Saying it was made clang
 * zero an Osenv's copy with `movaps %xmm0, 0x140(%r14)` in newprog,
 * and #GP the first time a Limbo program spawned another: the address
 * is not aligned in the block malloc returned.  The hardware alignment
 * requirement is met where the instruction runs, inside fp.S, not in
 * the declaration.
 *
 * FPenv (in Osenv, beside the other per-process state Dis swaps) and
 * FPU (in Proc, for the scheduler) are the same image.
 */
struct FPenv
{
	uchar	state[512];
};

enum
{
	FPINIT,
	FPACTIVE,
	FPINACTIVE,
};

struct FPU
{
	uchar	state[512];
};

/*
 * Machine configuration, filled in at boot.  ulong holds addresses here
 * only because ulong is 64 bits (u.h).
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

/* Per-processor state.  One core so far, so one Mach. */
struct Mach
{
	int		machno;
	uintptr		splpc;		/* pc of the last caller to splhi */
	Proc*		proc;		/* current process on this processor */
	Label		sched;		/* scheduler's saved context */
	Lock		alarmlock;	/* access to the alarm list */
	void*		alarm;		/* alarms bound to this clock */
	ulong		ticks;		/* of the clock, since boot */
	ulong		cpuhz;
	int		nrdy;
	ulong		idleticks;	/* ticks that found no process here */
	int		stack[1];
};

extern struct Active
{
	Lock	l;
	int	machs;			/* bitmap of active CPUs */
	int	exiting;		/* shutdown */
	int	ispanic;		/* shutdown in response to a panic */
	int	thunderbirdsarego;	/* secondaries may enter schedinit */
} active;

/*
 * The current process.  With one core, m is a plain global and up is
 * m's proc field, which is what makes "up = p" per-processor on a
 * machine that has only one.
 *
 * up is not spelled `(m->proc)`: os/port files declare locals named m
 * (qio.c's qread has `int m, n`), and a macro mentioning m would
 * dereference that integer at every waserror().  The accessor names m
 * only inside a function where no local can shadow it.
 */
extern Mach	machs[MAXMACH];
extern Mach	*m;

static inline Proc**
upaddr(void)
{
	return &m->proc;
}
#define	up	(*upaddr())
