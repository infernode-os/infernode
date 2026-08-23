/*
 * Kernel entry for the bare-metal BCM2837 port.
 *
 * Bring-up order matters here: the console comes up first so that
 * everything after it can report, then the exception vectors so that
 * anything that goes wrong after THAT reports too rather than hanging.
 */

#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

static u64int
currentel(void)
{
	u64int el;

	__asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
	return el >> 2;
}

static u64int
mpidr(void)
{
	u64int v;

	__asm__ volatile("mrs %0, mpidr_el1" : "=r"(v));
	return v;
}

static u64int
midr(void)
{
	u64int v;

	__asm__ volatile("mrs %0, midr_el1" : "=r"(v));
	return v;
}

/*
 * Prove the exception path round trips before relying on it.  A BRK
 * raises a synchronous exception; trap() reports it and steps over the
 * instruction, so reaching the line after this means the full save,
 * dispatch and restore worked.
 */
static void
checktraps(void)
{
	uartputs("trap: testing exception path with BRK...");
	__asm__ volatile("brk #0");
	uartputs("trap: returned from exception, save/restore OK\n");
}

void
kmain(void)
{
	uartinit();

	uartputs("\nInferNode bare-metal (BCM2837 / Raspberry Pi 3B+)\n");

	uartputs("  exception level: EL");
	uartputc('0' + (int)currentel());
	uartputs("\n  midr_el1:        ");
	uartputx(midr());
	uartputs("\n  mpidr_el1:       ");
	uartputx(mpidr());
	uartputs("\n  console:         PL011 UART0, polled\n");

	trapinit();
	uartputs("  vectors:         installed at VBAR_EL1\n\n");

	checktraps();

	uartputs("\nboot OK\n");

	for(;;)
		__asm__ volatile("wfe");
}
