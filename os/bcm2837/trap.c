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
	uartputs(kind[t & 3]);
	uartputs(" from ");
	return from[(t >> 2) & 3];
}

void
dumpureg(Ureg *u)
{
	int i;

	uartputs("\n  vector:  ");
	uartputs(slotname(u->type));
	uartputs("\n  esr:     ");
	uartputx(u->esr);
	uartputs("  ec=");
	uartputx((u->esr >> ESRECSHIFT) & ESRECMASK);
	uartputs(" (");
	uartputs(ecname((u32int)((u->esr >> ESRECSHIFT) & ESRECMASK)));
	uartputs(")\n  iss:     ");
	uartputx(u->esr & ESRISSMASK);
	uartputs("\n  far:     ");
	uartputx(u->far);
	uartputs("\n  elr(pc): ");
	uartputx(u->pc);
	uartputs("\n  spsr:    ");
	uartputx(u->psr);
	uartputs("\n  sp:      ");
	uartputx(u->sp);
	uartputs("\n");

	for(i = 0; i < 31; i++){
		if((i % 2) == 0)
			uartputs("  ");
		uartputs("x");
		uartputd(i);
		uartputs(i < 10 ? ":  " : ": ");
		uartputx(u->r[i]);
		uartputs((i % 2) ? "\n" : "   ");
	}
	uartputs("\n");
}

void
panic(char *msg)
{
	uartputs("\npanic: ");
	uartputs(msg);
	uartputs("\nhalted.\n");
	for(;;)
		__asm__ volatile("wfe");
}

void
trap(Ureg *u)
{
	u32int ec;

	ec = (u32int)((u->esr >> ESRECSHIFT) & ESRECMASK);

	/*
	 * BRK is recoverable: report it and step over the instruction.
	 * ELR points AT the brk, so advance one instruction to resume.
	 */
	if(ec == 0x3C){
		uartputs("\ntrap: BRK #");
		uartputd(u->esr & 0xFFFF);
		uartputs(" at pc=");
		uartputx(u->pc);
		uartputs(" -- stepping over\n");
		u->pc += 4;
		return;
	}

	uartputs("\n*** unhandled exception ***");
	dumpureg(u);
	panic("unhandled exception");
}
