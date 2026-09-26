/*
 * Platform data types for the bare-metal RISC-V (RV64GC) kernel.
 *
 * The shape of ../arm64/dat.h, which says at length why each type is
 * as it is; what is RISC-V's own is noted where it differs. Every .c
 * includes u.h first and this after (the Plan 9 convention upstream
 * os/port is written in); machine types, then ../port/portdat.h, then
 * Mach, which holds a Proc*.
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
 * sp, the resume pc, and every callee-saved register (s0-s11). Saving
 * only sp and pc is wrong under an optimising compiler for the reason
 * ../arm64/dat.h gives: gotolabel skips the epilogues that would have
 * restored the callee-saved registers. Order must match arch.S.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;
	uintptr	regs[12];	/* s0-s11 */
};

/* A spin lock; see ../arm64/dat.h. _tas works on key. */
struct Lock
{
	ulong	key;
	ulong	sr;
	uintptr	pc;
	int	pri;
};

/*
 * Floating-point state: f0-f31 and fcsr. FPsave in arch.S writes 32
 * doublewords then fcsr at offset 256; os/port/dis.c saves into an
 * FPenv, the scheduler into an FPU, so both are this shape.
 */
struct FPenv
{
	uvlong	regs[32];
	u32int	fcsr;
	u32int	pad;
};

enum
{
	FPINIT,
	FPACTIVE,
	FPINACTIVE,
};

struct FPU
{
	uvlong	regs[32];
	u32int	fcsr;
	u32int	pad;
};

/*
 * Machine configuration, filled in at boot. ulong holds an address
 * here only because ulong is 64 bits (u.h).
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
 * Per-processor state. machno is the kernel's index (0..MAXMACH-1);
 * hartid is the hart's own number, which is not the same thing: SBI
 * boots whichever hart wins its lottery, and a PolarFire SoC's first
 * application hart is hart 1 (hart 0 is the E51 monitor core).
 */
struct Mach
{
	int		machno;		/* index into machs[] */
	uintptr		splpc;		/* pc of the last caller to splhi */
	Proc*		proc;		/* current process on this processor */
	Label		sched;		/* scheduler's saved context */
	Lock		alarmlock;	/* access to the alarm list */
	void*		alarm;		/* alarms bound to this clock */
	ulong		ticks;		/* of the clock, since boot */
	ulong		cpuhz;
	int		nrdy;
	ulong		hartid;		/* the hart this Mach runs on */
	int		stack[1];
};

/* Which processors are up, and whether we are shutting down: see ../arm64/dat.h */
extern struct Active
{
	Lock	l;
	int	machs;			/* bitmap of active CPUs */
	int	exiting;		/* shutdown */
	int	ispanic;		/* shutdown in response to a panic */
	int	thunderbirdsarego;	/* secondaries may enter schedinit */
} active;

/*
 * The per-core pointer lives in tp, the thread pointer. The psABI
 * reserves tp and no compiler allocates it, so unlike x28 on arm64 it
 * needs no -ffixed flag: each hart's boot path loads its own Mach*
 * there before running any C, and the trap path saves it but does NOT
 * restore it (vectors.S), because a process preempted on one hart may
 * resume on another and must see that hart's Mach, not the one it left.
 * The JIT (libinterp/comp-riscv64.c) never touches tp.
 */
register Mach	*m asm("tp");

/*
 * up reads tp through the assembler, volatile, for the reason
 * ../arm64/dat.h gives for x28: a cached copy survives migration.
 */
static inline Proc**
_upaddr(void)
{
	Mach *mm;

	__asm__ __volatile__("mv %0, tp" : "=r"(mm));
	return &mm->proc;
}
#define	up	(*_upaddr())

extern Mach	machs[];
#define	MACHP(n)	(&machs[n])

/* A linear 32-bit XRGB framebuffer (../arm64/dat.h) */
typedef struct Fbinfo Fbinfo;

struct Fbinfo
{
	u32int	disp;
	uintptr	base;
	u32int	size;
	u32int	pitch;
	u32int	width;
	u32int	height;
	u32int	depth;
};
