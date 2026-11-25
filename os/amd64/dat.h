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
 * x87 state, as os/port's FP save/restore expects it.  Nothing saves or
 * restores it yet -- the kernel is built -mno-sse and does not run the
 * Dis VM -- but Proc embeds an FPU, so the shape has to exist now.
 */
struct FPenv
{
	u16int	fcr;		/* control word */
	u16int	fsr;		/* status word */
	u16int	tag;		/* tag word */
	uchar	regs[8][10];	/* ST(0)-ST(7) */
};

enum
{
	FPINIT,
	FPACTIVE,
	FPINACTIVE,
};

struct FPU
{
	u16int	fcr;
	u16int	fsr;
	u16int	tag;
	uchar	regs[8][10];
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
 */
extern Mach	machs[MAXMACH];
extern Mach	*m;
#define	up	(m->proc)
