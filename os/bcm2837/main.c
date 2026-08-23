/*
 * Kernel entry for the bare-metal BCM2837 port.
 *
 * At this stage the only job is to prove the toolchain and the boot path:
 * a cross-built AArch64 image loads at the right address, one core runs,
 * .bss is clear, and the console works.  Everything past that -- exception
 * vectors, MMU, timer, the Dis VM itself -- follows from here.
 */

#include "dat.h"
#include "io.h"

void	uartinit(void);
void	uartputc(int);
void	uartputs(char*);

static void
uartputx(u64int v)
{
	char buf[16];
	int i;

	for(i = 15; i >= 0; i--){
		buf[i] = "0123456789abcdef"[v & 0xF];
		v >>= 4;
	}
	uartputs("0x");
	for(i = 0; i < 16; i++)
		uartputc(buf[i]);
}

/*
 * Which exception level the firmware left us in decides how much setup
 * is needed before EL1 kernel code can run.  The VideoCore firmware
 * normally enters at EL2 on the Pi 3, so this is worth knowing early.
 */
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

void
kmain(void)
{
	uartinit();

	uartputs("\nInferNode bare-metal (BCM2837 / Raspberry Pi 3B+)\n");

	uartputs("  exception level: EL");
	uartputc('0' + (int)currentel());
	uartputs("\n  mpidr_el1:       ");
	uartputx(mpidr());
	uartputs("\n  console:         PL011 UART0, polled\n");
	uartputs("boot OK\n");

	for(;;)
		__asm__ volatile("wfe");
}
