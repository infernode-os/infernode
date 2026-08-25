/*
 * BCM2837 board hooks.
 *
 * The five functions ../arm64/fns.h declares as this platform's half of
 * the boot sequence, and nothing else. Everything here touches hardware
 * that exists only on this SoC: the VideoCore mailbox, the GPIO block,
 * the fixed-rate system timer and the firmware framebuffer.
 *
 * These were inline in main.c until os/virt arrived, which is the point
 * at which "which board is this" stopped being a rhetorical question.
 * The split is worth keeping at two boards rather than deferring: it is
 * what stops the shared kmain from growing #ifdefs.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

char*
boardname(void)
{
	return "BCM2837 / Raspberry Pi 3B+";
}

/*
 * Ask the firmware what board this is.  Cheap, and it is the first
 * confirmation that the mailbox round trip works at all -- worth having
 * before anything depends on the mailbox for something harder to debug.
 */
void
boardprobe(void)
{
	u32int v[2];

	uartputstr("mbox: ");
	v[0] = 0;
	if(mboxprop(Taggetrev, v, 0, 1) == 0){
		uartputstr("board rev ");
		uartputx(v[0]);
	}else{
		uartputstr("board rev query FAILED");
	}

	v[0] = 0;
	v[1] = 0;
	if(mboxprop(Taggetarmmem, v, 0, 2) == 0){
		uartputstr(", ARM memory ");
		uartputd(v[1] >> 20);
		uartputstr("MB at ");
		uartputx(v[0]);
	}
	uartputstr("\n");
}

/*
 * Read back the pin mux the UART set up.
 *
 * Deliberately non-invasive: it only READS function selects, and only
 * for pins this kernel already configured.  Driving an arbitrary pin as
 * a self-test would be reckless on real hardware, where something may be
 * wired to it -- the header pins are attached to whatever the owner
 * plugged in, and a test that asserts an output could short a driven
 * line.  Reading back proves the mux took, which is the part that is
 * otherwise invisible.
 */
void
boardioprobe(void)
{
	int f14, f15;

	f14 = gpiogetfunc(14);
	f15 = gpiogetfunc(15);

	uartputstr("gpio: pin14 func=");
	uartputd(f14);
	uartputstr(" pin15 func=");
	uartputd(f15);
	if(f14 == Gpioalt0 && f15 == Gpioalt0)
		uartputstr(" (ALT0/UART as set) OK\n");
	else
		uartputstr(" UNEXPECTED (wanted ALT0 on both)\n");
}

/*
 * Cross-check CNTFRQ_EL0 against the BCM system timer.
 *
 * CNTFRQ_EL0 is not derived by the hardware -- it is a value firmware
 * writes, and firmware can write the wrong one. If it lies, every delay
 * and timeout in the kernel is off by that ratio, and the symptom is
 * never "the clock is wrong": it is flaky networking, or a display that
 * tears, or timeouts that fire early under load.
 *
 * The BCM system timer runs at a fixed 1MHz set by the hardware rather
 * than reported by firmware, so timing the same interval with both and
 * comparing catches it immediately. Having a second, independently-rated
 * clock is exactly what makes this check possible -- and is the reason
 * it is a board hook rather than portable code.
 */
void
boardclockcheck(void)
{
	u64int c0, c1, s0, s1, genus, sysus, lo, hi;

	/* time 50ms by both clocks */
	s0 = systimer();
	c0 = clockcount();
	microdelay(50000);
	c1 = clockcount();
	s1 = systimer();

	sysus = s1 - s0;
	genus = ((c1 - c0) * 1000000) / clockfreq();

	uartputstr("clk:  50ms measured: systimer ");
	uartputd(sysus);
	uartputstr("us, generic ");
	uartputd(genus);
	uartputstr("us -- ");

	/* agree within 5%? */
	lo = (sysus * 95) / 100;
	hi = (sysus * 105) / 100;
	if(genus >= lo && genus <= hi)
		uartputstr("clocks AGREE\n");
	else
		uartputstr("clocks DISAGREE (cntfrq is lying)\n");
}

/*
 * Static, because the console keeps a pointer to it.
 *
 * This was a local, which was correct while the framebuffer was only
 * ever painted once from inside this function. A console outlives the
 * probe that finds the screen.
 */
static Fbinfo fb;

void
boardfbprobe(void)
{
	if(fbinit(&fb) < 0){
		uartputstr("fb:   no framebuffer (no display attached?)\n");
		return;
	}

	uartputstr("fb:   ");
	uartputd(fb.width);
	uartputstr("x");
	uartputd(fb.height);
	uartputstr("x");
	uartputd(fb.depth);
	uartputstr(" pitch=");
	uartputd(fb.pitch);
	uartputstr(" base=");
	uartputx(fb.base);
	uartputstr(" size=");
	uartputd(fb.size);
	uartputstr("\n");

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
	uartputstr("fb:   test pattern drawn\n");

	/*
	 * Take the screen as a console.
	 *
	 * putstrn0 already calls screenputs when there is one; installing
	 * it here is what makes every kernel print appear on the panel as
	 * well as on the wire. consoleprint has to be set too: it
	 * defaults to 0, which gates both this and the echo of typed
	 * characters.
	 */
	if(fbconsinit(&fb) == 0){
		screenputs = fbconsputs;
		consoleprint = 1;
		uartputstr("fb:   console on the panel\n");
	}
}

/*
 * Reset the machine.
 *
 * This SoC has no reset line to assert: rebooting means arming the
 * watchdog with a short timeout and letting it expire. Every write to
 * the power-management block needs the password in the top half, and a
 * write without it is ignored SILENTLY -- which is the failure mode to
 * watch for if this ever stops working.
 *
 * It matters for more than tidiness here. The kernel is delivered over
 * the serial line by serialboot, which only runs at reset, so without
 * a way to reset from software every iteration needs a human to pull
 * the power. With it, the loop closes: send a kernel, run it, write
 * "reboot" to #c/sysctl, send the next one.
 */
void
boardreboot(void)
{
	volatile u32int *rstc, *wdog;

	rstc = (u32int*)(uintptr)(PMREGS + Pmrstc);
	wdog = (u32int*)(uintptr)(PMREGS + Pmwdog);

	*wdog = Pmpassword | 16;		/* a few ticks is plenty */
	*rstc = Pmpassword | (*rstc & Pmwrcfgclr) | Pmwrcfgfull;
	coherence();

	for(;;)
		;
}
