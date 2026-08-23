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

/*
 * Ask the firmware what board this is.  Cheap, and it is the first
 * confirmation that the mailbox round trip works at all -- worth having
 * before anything depends on the mailbox for something harder to debug.
 */
static void
probehw(void)
{
	u32int v[2];

	uartputs("mbox: ");
	v[0] = 0;
	if(mboxprop(Taggetrev, v, 0, 1) == 0){
		uartputs("board rev ");
		uartputx(v[0]);
	}else{
		uartputs("board rev query FAILED");
	}

	v[0] = 0;
	v[1] = 0;
	if(mboxprop(Taggetarmmem, v, 0, 2) == 0){
		uartputs(", ARM memory ");
		uartputd(v[1] >> 20);
		uartputs("MB at ");
		uartputx(v[0]);
	}
	uartputs("\n");
}

static void
probefb(void)
{
	Fbinfo fb;

	if(fbinit(&fb) < 0){
		uartputs("fb:   no framebuffer (no display attached?)\n");
		return;
	}

	uartputs("fb:   ");
	uartputd(fb.width);
	uartputs("x");
	uartputd(fb.height);
	uartputs("x");
	uartputd(fb.depth);
	uartputs(" pitch=");
	uartputd(fb.pitch);
	uartputs(" base=");
	uartputx(fb.base);
	uartputs(" size=");
	uartputd(fb.size);
	uartputs("\n");

	/*
	 * Paint something identifiable.  On the 7in panel this is the
	 * first thing that will ever be visible, so make it unambiguous
	 * rather than a single colour that could be a stuck backlight.
	 */
	fbfill(&fb, 0x00101018);
	fbrect(&fb, 0, 0, (int)fb.width, 8, 0x00C03020);
	fbrect(&fb, 20, 40, 120, 80, 0x00FF0000);
	fbrect(&fb, 160, 40, 120, 80, 0x0000FF00);
	fbrect(&fb, 300, 40, 120, 80, 0x000000FF);
	uartputs("fb:   test pattern drawn\n");
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

	probehw();
	probefb();

	uartputs("\nboot OK\n");

	for(;;)
		__asm__ volatile("wfe");
}
