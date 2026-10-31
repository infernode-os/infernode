/*
 * Serial recovery: the way back from a kernel that does not work.
 *
 * The Pi 3B+'s, ../bcm2837/recover.c, which says why it exists and why
 * it is safe to call before mmuinit; this is that function for the
 * BCM2711. It is a copy and not an #include because a quoted #include
 * looks first in the including file's directory, and that one's "mem.h",
 * "dat.h" and "fns.h" would then be the BCM2837's.
 *
 * The loader it hands over to is ../bcm2837/serialboot.c built at this
 * SoC's peripheral base (tests/host/baremetal_test.sh). On the board the
 * ETX asking for it and the loader's own traffic share one pair of wires:
 * the kernel's console is the mini-UART on GPIO 14/15, and serialboot
 * moves those two pins to the PL011, as it does on a Pi 3.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

extern uchar serialbootimg[];
extern int nserialbootimg;

enum {
	Recovchar	= 0x03,		/* ETX; serialboot's own handshake byte */
	Recovwait	= 50,		/* ms; see ../bcm2837/recover.c */
	Recovaddr	= 32*1024*1024,	/* where serialboot is linked to run */
	Drainmax	= 64,		/* bytes to look at per millisecond */
};

void
serialrecover(void)
{
	int i, n, c, asked;
	void (*loader)(void);

	if(nserialbootimg <= 0)
		return;

	uartputstr("boot: send ^C now for the serial loader\n");

	asked = 0;
	for(i = 0; i < Recovwait && !asked; i++){
		/* bounded: a host streaming at the console must not pin the boot here */
		for(n = 0; n < Drainmax; n++){
			c = uartgetc();
			if(c < 0)
				break;
			if(c == Recovchar){
				asked = 1;
				break;
			}
		}
		if(!asked)
			microdelay(1000);
	}
	if(!asked)
		return;

	uartputstr("boot: handing over to serialboot\n");

	memmove((void*)Recovaddr, serialbootimg, nserialbootimg);
	cachedwbinvse((void*)Recovaddr, nserialbootimg);

	loader = (void(*)(void))Recovaddr;
	(*loader)();

	uartputstr("boot: serialboot returned -- this should not happen\n");
	for(;;)
		;
}
