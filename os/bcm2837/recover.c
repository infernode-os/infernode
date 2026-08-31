/*
 * Serial recovery: the way back from a kernel that does not work.
 *
 * THE PROBLEM THIS EXISTS FOR. The firmware loads one file, named in
 * config.txt, and until now that file was serialboot -- so every boot
 * waited for a kernel to be pushed down the wire, and the board could
 * not start on its own. Installing a kernel as that file instead makes
 * the board autonomous and takes the cable out of the daily loop, but
 * it also removes the loader: a kernel that faults before it can be
 * talked to is then unreachable, and the card has to come out and go
 * into a reader. On a board whose whole purpose is developing drivers,
 * that is not a hypothetical.
 *
 * So the kernel carries the loader inside it and offers it back at the
 * start of every boot. An installed kernel is then its own recovery
 * path: reset the board, ask within the window, and the loader takes
 * over exactly as it did when it owned the boot file.
 *
 * WHY THIS IS SIMPLER THAN IT SOUNDS. serialboot is linked to run at
 * 32MB and relocates itself there if it is entered anywhere else, and
 * it deliberately does not touch the MMU -- see the comment at the top
 * of serialboot.S. Running it therefore needs no trampoline and no
 * teardown, provided we hand over while the machine is still in the
 * state it was booted in. That is why this is called BEFORE mmuinit:
 * translation and caches are still off, which is precisely the
 * environment the loader was written for. Copy it to where it expects
 * to be and branch.
 *
 * It also means the window opens as early as a window usefully can --
 * after the UART works and before anything else is configured -- so
 * almost nothing a later change can break is able to break the way
 * back.
 *
 * WHY IT ASKS FOR A CHARACTER RATHER THAN A PAUSE. A window that hands
 * over on any input would be tripped by line noise and by a person
 * leaning on the keyboard, and the failure is unpleasant: the board
 * sits in the loader looking like a hang. It waits for ETX instead --
 * the same byte serialboot itself sends as its handshake, which no
 * shell prompt and no console echo produces.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

/*
 * The loader itself, as bytes. Generated at build time from the same
 * serialboot.img that is written to the card, so the copy carried here
 * and the copy on the card cannot drift apart.
 */
extern uchar serialbootimg[];
extern int nserialbootimg;

enum {
	Recovchar	= 0x03,		/* ETX; serialboot's own handshake byte */
	/*
	 * A quarter of a second, and it does not want to be longer.
	 *
	 * The first version waited a second and a half and cost seven
	 * checks in the harness -- the framebuffer screenshot, the shell
	 * session, the keyboard enumeration -- none of them broken, all
	 * of them simply given a second and a half less boot inside
	 * their own windows. Every boot pays this, so it is not free.
	 *
	 * It does not need to be long. The host asks by SENDING ETX
	 * continuously from the moment it resets the board, so by the
	 * time this runs the byte is already sitting in the receive
	 * FIFO; the window is covering jitter between the reset and this
	 * check, not waiting for a human to decide.
	 */
	Recovwait	= 250,		/* ms to wait before giving up on it */
	Recovaddr	= 32*1024*1024,	/* where serialboot is linked to run */
};

/*
 * Wait briefly for the host to ask for the loader, and hand over if it
 * does. Returns normally if nobody asked, which is the ordinary case
 * and must stay cheap -- a quarter of a second on every boot, paid
 * whether or not anyone ever needs it.
 */
void
serialrecover(void)
{
	int i, c, asked;
	void (*loader)(void);

	if(nserialbootimg <= 0)
		return;

	uartputstr("boot: send ^C now for the serial loader\n");

	/*
	 * Polled, not timed off the clock: this runs before clockinit,
	 * so there is no tick to wait on yet. microdelay is calibrated
	 * from the generic timer's fixed frequency and works from reset.
	 */
	asked = 0;
	for(i = 0; i < Recovwait; i++){
		c = uartgetc();
		if(c == Recovchar){
			asked = 1;
			break;
		}
		microdelay(1000);
	}
	if(!asked)
		return;

	uartputstr("boot: handing over to serialboot\n");

	/*
	 * Copy, then make sure the copy is visible to instruction fetch.
	 *
	 * Caches are off here, so this is belt and braces rather than
	 * strictly required -- but it costs microseconds and the failure
	 * it guards against is jumping into a partially written loader,
	 * which presents as a dead board rather than as an error.
	 */
	memmove((void*)Recovaddr, serialbootimg, nserialbootimg);
	cachedwbinvse((void*)Recovaddr, nserialbootimg);

	loader = (void(*)(void))Recovaddr;
	(*loader)();

	/*
	 * Not reached: serialboot loads a kernel over 0x80000 and jumps
	 * into it. If it ever does return, saying so is better than
	 * carrying on through a boot whose image has been overwritten
	 * underneath it.
	 */
	uartputstr("boot: serialboot returned -- this should not happen\n");
	for(;;)
		;
}
