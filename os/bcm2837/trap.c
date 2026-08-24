/*
 * Exception handling.
 *
 * Until there are processes to kill, every fault is fatal and the only
 * useful thing to do is say precisely what happened before stopping.
 * A silent hang during early bring-up costs hours; a register dump and
 * a decoded syndrome costs minutes.
 *
 * The exception is BRK, which is deliberately made recoverable: it is
 * how we test that the save/restore path in vectors.S actually round
 * trips, and later it is what a debugger breakpoint lands on.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

/* ESR_EL1 exception class, bits 31:26 */
#define ESRECSHIFT	26
#define ESRECMASK	0x3F
#define ESRISSMASK	0x1FFFFFF

static char*
ecname(u32int ec)
{
	switch(ec){
	case 0x00: return "unknown reason";
	case 0x01: return "trapped WFI/WFE";
	case 0x07: return "trapped SIMD/FP access";
	case 0x0E: return "illegal execution state";
	case 0x15: return "SVC (system call)";
	case 0x16: return "HVC";
	case 0x18: return "trapped MSR/MRS";
	case 0x20: return "instruction abort, lower EL";
	case 0x21: return "instruction abort, same EL";
	case 0x22: return "PC alignment fault";
	case 0x24: return "data abort, lower EL";
	case 0x25: return "data abort, same EL";
	case 0x26: return "SP alignment fault";
	case 0x2C: return "trapped FP exception";
	case 0x2F: return "SError";
	case 0x30: return "breakpoint, lower EL";
	case 0x31: return "breakpoint, same EL";
	case 0x32: return "software step, lower EL";
	case 0x33: return "software step, same EL";
	case 0x34: return "watchpoint, lower EL";
	case 0x35: return "watchpoint, same EL";
	case 0x3C: return "BRK instruction";
	}
	return "reserved/unhandled";
}

static char*
slotname(u64int t)
{
	static char *kind[] = { "sync", "irq", "fiq", "serror" };
	static char *from[] = {
		"current EL, SP_EL0",
		"current EL, SP_ELx",
		"lower EL, AArch64",
		"lower EL, AArch32",
	};

	if(t > 15)
		return "bad slot";
	uartputstr(kind[t & 3]);
	uartputstr(" from ");
	return from[(t >> 2) & 3];
}

void
dumpureg(Ureg *u)
{
	int i;

	uartputstr("\n  vector:  ");
	uartputstr(slotname(u->type));
	uartputstr("\n  esr:     ");
	uartputx(u->esr);
	uartputstr("  ec=");
	uartputx((u->esr >> ESRECSHIFT) & ESRECMASK);
	uartputstr(" (");
	uartputstr(ecname((u32int)((u->esr >> ESRECSHIFT) & ESRECMASK)));
	uartputstr(")\n  iss:     ");
	uartputx(u->esr & ESRISSMASK);
	uartputstr("\n  far:     ");
	uartputx(u->far);
	uartputstr("\n  elr(pc): ");
	uartputx(u->pc);
	uartputstr("\n  spsr:    ");
	uartputx(u->psr);
	uartputstr("\n  sp:      ");
	uartputx(u->sp);
	uartputstr("\n");

	for(i = 0; i < 31; i++){
		if((i % 2) == 0)
			uartputstr("  ");
		uartputstr("x");
		uartputd(i);
		uartputstr(i < 10 ? ":  " : ": ");
		uartputx(u->r[i]);
		uartputstr((i % 2) ? "\n" : "   ");
	}
	uartputstr("\n");
}

void
trap(Ureg *u)
{
	u32int ec;

	/*
	 * Interrupts first: they are the common case once the clock is
	 * running, and unlike a fault they carry no syndrome worth
	 * decoding.  An IRQ nobody claims is reported rather than
	 * silently dropped -- a stuck interrupt line that is quietly
	 * ignored presents as the kernel mysteriously making no progress.
	 */
	if(u->type == Tirq || u->type == Tirq0){
		if(!irqdispatch(u)){
			uartputstr("\ntrap: unhandled IRQ");
			dumpureg(u);
			panic("unhandled IRQ");
		}
		return;
	}

	ec = (u32int)((u->esr >> ESRECSHIFT) & ESRECMASK);

	/*
	 * BRK is recoverable: report it and step over the instruction.
	 * ELR points AT the brk, so advance one instruction to resume.
	 */
	if(ec == 0x3C){
		uartputstr("\ntrap: BRK #");
		uartputd(u->esr & 0xFFFF);
		uartputstr(" at pc=");
		uartputx(u->pc);
		uartputstr(" -- stepping over\n");
		u->pc += 4;
		return;
	}

	uartputstr("\n*** unhandled exception ***");
	dumpureg(u);
	panic("unhandled exception");
}

/*
 * Print a backtrace for the current process.
 *
 * os/port calls this when something has gone wrong enough to want the
 * stack. AArch64 frames are chained through x29 -- each frame stores the
 * caller's x29 and x30 at [x29] and [x29,#8] -- so the chain can be
 * walked without unwind tables, provided the code was built with frame
 * pointers. Bounded, because the whole point is to run when memory is
 * already suspect and a corrupt chain must not become an infinite loop.
 */
void
dumpstack(void)
{
	uintptr fp, pc, top;
	int i;

	__asm__ volatile("mov %0, x29" : "=r"(fp));

	top = (uintptr)m + KSTACK;
	print("stack trace:\n");
	for(i = 0; i < 32 && fp != 0; i++){
		if((fp & 7) != 0 || fp < conf.base0 || fp >= top + KSTACK)
			break;			/* chain is not credible */
		pc = *(uintptr*)(fp + 8);
		if(pc == 0)
			break;
		print("  %lux\n", (ulong)pc);
		fp = *(uintptr*)fp;
	}
}
