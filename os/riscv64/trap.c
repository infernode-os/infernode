/*
 * Trap handling: interrupts to their handlers; every exception but a
 * breakpoint and an expected probe fault is fatal, and says precisely
 * what happened before stopping (../arm64/trap.c says why).
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

extern char _start[], end[];
extern char bootstack[], bootstacktop[];

int	ipiintr(void);

enum
{
	Intrbit		= 63,

	Isoft		= 1,
	Itimer		= 5,
	Iext		= 9,

	Einstmisalign	= 0,
	Einstaccess	= 1,
	Eillegal	= 2,
	Ebreak		= 3,
	Eloadmisalign	= 4,
	Eloadaccess	= 5,
	Estoremisalign	= 6,
	Estoreaccess	= 7,
	Eecallu		= 8,
	Eecalls		= 9,
	Einstpage	= 12,
	Eloadpage	= 13,
	Estorepage	= 15,
};

static char*
causename(u64int cause)
{
	if(cause >> Intrbit){
		switch(cause & 0xFF){
		case Isoft:	return "software interrupt";
		case Itimer:	return "timer interrupt";
		case Iext:	return "external interrupt";
		}
		return "unknown interrupt";
	}
	switch(cause){
	case Einstmisalign:	return "instruction address misaligned";
	case Einstaccess:	return "instruction access fault";
	case Eillegal:		return "illegal instruction";
	case Ebreak:		return "breakpoint";
	case Eloadmisalign:	return "load address misaligned";
	case Eloadaccess:	return "load access fault";
	case Estoremisalign:	return "store address misaligned";
	case Estoreaccess:	return "store access fault";
	case Eecallu:		return "ecall from U-mode";
	case Eecalls:		return "ecall from S-mode";
	case Einstpage:		return "instruction page fault";
	case Eloadpage:		return "load page fault";
	case Estorepage:	return "store page fault";
	}
	return "reserved exception";
}

static char *regname[32] = {
	"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
	"s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
	"a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
	"s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

void
dumpureg(Ureg *u)
{
	int i, held;

	held = uartlock();
	uartputstr("\n  cause:   ");
	uartputx(u->cause);
	uartputstr(" (");
	uartputstr(causename(u->cause));
	uartputstr(")\n  tval:    ");
	uartputx(u->tval);
	uartputstr("\n  pc:      ");
	uartputx(u->pc);
	uartputstr("\n  status:  ");
	uartputx(u->status);
	uartputstr("\n  hart:    ");
	uartputd(m->hartid);
	uartputstr(" (cpu");
	uartputd(m->machno);
	uartputstr(")");
	if(up != nil && up->kstack != nil){
		uartputstr("\n  kstack:  ");
		uartputx((uintptr)up->kstack);
		uartputstr("..");
		uartputx((uintptr)up->kstack + KSTACK);
		uartputstr(u->sp >= (uintptr)up->kstack &&
			   u->sp <= (uintptr)up->kstack + KSTACK
				? " (sp inside)" : " (sp OUTSIDE -- stack overflow?)");
		uartputstr("\n  pid:     ");
		uartputd(up->pid);
	}
	uartputstr("\n");
	for(i = 1; i < 32; i++){
		uartputstr("  ");
		uartputstr(regname[i]);
		uartputstr(": ");
		uartputx(u->r[i]);
		uartputstr((i % 2) == 0 ? "\n" : "");
	}
	uartputstr("\n");

	/*
	 * The call chain of the code that trapped. With frame pointers the
	 * psABI puts the return address at fp-8 and the caller's fp at
	 * fp-16.
	 */
	uartputstr("  trace:   ");
	{
		uintptr fp, pc;

		fp = u->r[8];
		for(i = 0; i < 16; i++){
			if((fp & 7) != 0 || fp < 0x1000 || fp >= mmuhightop())
				break;
			pc = *(uintptr*)(fp - 8);
			if(pc < 0x1000 || pc >= mmuhightop())
				break;
			uartputx(pc);
			uartputstr(" ");
			fp = *(uintptr*)(fp - 16);
		}
	}
	uartputstr("\n");
	uartunlock(held);
}

static int panicking;

/*
 * Is there anything at this address? One 32-bit load with a per-hart
 * flag up that tells trap() to step over it if it faults: see
 * ../arm64/trap.c.
 */
static int probing[MAXMACH];
static int probefault[MAXMACH];

int
probe32(uintptr addr, u32int *vp)
{
	volatile u32int *p;
	u32int v;
	int s, bad;

	p = (volatile u32int*)addr;
	s = splhi();
	probefault[m->machno] = 0;
	probing[m->machno] = 1;
	coherence();
	v = *p;
	coherence();
	probing[m->machno] = 0;
	bad = probefault[m->machno];
	splx(s);
	if(bad)
		return -1;
	if(vp != nil)
		*vp = v;
	return 0;
}

/* the length of the instruction at pc: 2 if compressed */
static int
inslen(uintptr pc)
{
	return (*(u16int*)pc & 3) == 3 ? 4 : 2;
}

void
trap(Ureg *u)
{
	u64int cause;

	if(up != nil && up->kstack != nil && *(ulong*)up->kstack != KSTACKGUARD){
		uartputstr("\n*** kernel stack overflow: guard word clobbered ***");
		dumpureg(u);
		panic("kstack overflow");
	}

	/* every stack is the boot stack, or at or above end (see ../arm64/trap.c) */
	if(u->sp >= (uintptr)_start && u->sp < (uintptr)end &&
	   !(u->sp >= (uintptr)bootstack && u->sp <= (uintptr)bootstacktop)){
		uartputstr("\n*** trap taken on an impossible stack ***");
		dumpureg(u);
		panic("sp inside the kernel image");
	}

	cause = u->cause;
	if(cause >> Intrbit){
		switch(cause & 0xFF){
		case Itimer:
			clockintr(u);
			return;
		case Isoft:
			ipiintr();
			return;
		case Iext:
			if(!irqdispatch(u)){
				uartputstr("\ntrap: unhandled external interrupt\n");
				intrdump();
				dumpureg(u);
				panic("unhandled interrupt");
			}
			return;
		}
		uartputstr("\ntrap: unexpected interrupt\n");
		dumpureg(u);
		panic("unexpected interrupt");
	}

	/* a breakpoint is recoverable: report it and step over it */
	if(cause == Ebreak){
		uartputstr("\ntrap: breakpoint at pc=");
		uartputx(u->pc);
		uartputstr(" -- stepping over\n");
		u->pc += inslen(u->pc);
		return;
	}

	/* an expected fault: probe32() asking whether an address answers */
	if((cause == Eloadaccess || cause == Eloadpage) && probing[m->machno]){
		probing[m->machno] = 0;
		probefault[m->machno] = 1;
		u->pc += inslen(u->pc);
		return;
	}

	uartputstr("\n*** unhandled exception ***");
	if(panicking++){
		uartputstr(" NESTED -- halting to preserve the first report\n");
		splhi();
		for(;;)
			idlewfi();
	}
	dumpureg(u);
	panic("unhandled exception: %s", causename(cause));
}

/* a backtrace of the current process, walked through s0 (../arm64/trap.c) */
void
dumpstack(void)
{
	uintptr fp, pc, top;
	int i;

	__asm__ volatile("mv %0, s0" : "=r"(fp));
	top = mmuhightop();
	print("stack trace:\n");
	for(i = 0; i < 32 && fp != 0; i++){
		if((fp & 7) != 0 || fp < 0x1000 || fp >= top)
			break;
		pc = *(uintptr*)(fp - 8);
		if(pc == 0)
			break;
		print("  %lux\n", (ulong)pc);
		fp = *(uintptr*)(fp - 16);
	}
}
