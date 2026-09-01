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

	/*
	 * Where the stack pointer is matters more than its value.
	 *
	 * A kernel stack that has run off its allocation does not fault:
	 * it simply walks down into whatever the pool handed out below
	 * it, so the corruption appears somewhere else entirely and the
	 * eventual crash is a jump to an address read back off the
	 * damaged stack. Saying whether sp is still inside up->kstack
	 * turns that from a guess into a fact, at the one moment the
	 * question is being asked.
	 */
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

	/*
	 * The call chain of the code that FAULTED, walked from the saved
	 * x29 -- not from here, which would only show the trap handler
	 * looking at itself. Each credible frame stores the caller's
	 * {x29, x30} at [x29]; the bound is RAM, because kprocs run on
	 * pool-allocated stacks and any tighter guess (the old
	 * "m + KSTACK", from when m sat on the boot stack) rejects every
	 * real frame and prints an empty trace at the exact moment one
	 * is needed.
	 */
	uartputstr("  trace:  ");
	{
		uintptr fp, pc;
		fp = u->r[29];
		for(i = 0; i < 16; i++){
			if((fp & 7) != 0 || fp < 0x1000 || fp >= mmuramtop())
				break;
			pc = *(uintptr*)(fp + 8);
			if(pc < 0x1000 || pc >= mmuramtop())
				break;
			uartputx(pc);
			uartputstr(" ");
			fp = *(uintptr*)fp;
		}
	}
	uartputstr("\n");
}

/* kernel image bounds, from the linker script */
extern char _start[], end[];

static int panicking;

void
trap(Ureg *u)
{
	u32int ec;

	/*
	 * Catch a bad stack at the first exception taken on it.
	 *
	 * Every stack in this kernel is either below the image (the boot
	 * stack, set to _start in l.S) or at or above `end` (a kstack from
	 * smalloc). An sp inside [_start, end) is impossible, and by the
	 * time it shows up as a wild pc the code that set it is long gone.
	 *
	 * Reporting here names the instruction that was actually running
	 * on it. Without this the earliest catch was sched(), which only
	 * says a bogus stack reached the scheduler -- true, and far too
	 * late to attribute.
	 */
	/*
	 * Has the current process run off the bottom of its kernel stack?
	 * Checked before the sp-range test because it is the more specific
	 * answer: it names the process that did it, rather than merely
	 * observing that sp is somewhere it should not be.
	 */
	if(up != nil && up->kstack != nil && *(ulong*)up->kstack != KSTACKGUARD){
		uartputstr("\n*** kernel stack overflow: guard word clobbered ***");
		dumpureg(u);
		panic("kstack overflow");
	}

	if(u->sp >= (uintptr)_start && u->sp < (uintptr)end){
		uartputstr("\n*** exception taken on an impossible stack ***");
		dumpureg(u);
		panic("sp inside the kernel image");
	}

	/*
	 * Interrupts first: they are the common case once the clock is
	 * running, and unlike a fault they carry no syndrome worth
	 * decoding.  An IRQ nobody claims is reported rather than
	 * silently dropped -- a stuck interrupt line that is quietly
	 * ignored presents as the kernel mysteriously making no progress.
	 */
	if(u->type == Tirq || u->type == Tirq0){
		if(!irqdispatch(u)){
			uartputstr("\ntrap: unhandled IRQ\n");
			intrdump();
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

	/*
	 * One dump, then stop.
	 *
	 * A fault taken while reporting a fault is not additional
	 * information, it is the destruction of the information already
	 * printed: the handler re-enters, prints the banner again, and
	 * overwrites the register dump that identified the ORIGINAL fault
	 * with one describing the wreckage. Observed as a console full of
	 * half-printed banners and nothing usable in between.
	 *
	 * The emergency stack above catches the case where sp points into
	 * the kernel image, but it cannot help when sp merely points at
	 * the wrong heap allocation -- which is the common one here. So
	 * bound the recursion explicitly rather than relying on the frame
	 * landing somewhere survivable.
	 */
	if(panicking++){
		uartputstr(" NESTED -- halting to preserve the first report\n");
		splhi();
		for(;;)
			__asm__ volatile("wfi");
	}

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

	/*
	 * Bound by RAM. The old bound was "m + KSTACK" from the days when
	 * m lived on the boot stack; m is machs[] in .bss now, so that
	 * bound rejected every pool-allocated kproc stack and this
	 * function printed nothing exactly when it was wanted.
	 */
	top = mmuramtop();
	print("stack trace:\n");
	for(i = 0; i < 32 && fp != 0; i++){
		if((fp & 7) != 0 || fp < 0x1000 || fp >= top)
			break;			/* chain is not credible */
		pc = *(uintptr*)(fp + 8);
		if(pc == 0)
			break;
		print("  %lux\n", (ulong)pc);
		fp = *(uintptr*)fp;
	}
}
