/*
 * The two timers every Raspberry Pi SoC has besides the ARM generic
 * timer, which is the architecture's and is each board's clock: the
 * VideoCore system timer, and the SP804-like "ARM timer".
 *
 * Neither keeps this kernel's time. They were in os/bcm2837/clock.c
 * and are here because a second SoC (os/bcm2711) has the same two
 * blocks and a different clock.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define ST(r)	(*(volatile u32int*)((uintptr)SYSTIMERREGS + (r)))

/*
 * The BCM system timer, read as a 64-bit value.  Read high, then low,
 * then high again: if the high word changed, the low word wrapped
 * between the two reads and the pair is inconsistent, so try again.
 */
u64int
systimer(void)
{
	u32int hi, lo, hi2;

	for(;;){
		hi = ST(Stchi);
		lo = ST(Stclo);
		hi2 = ST(Stchi);
		if(hi == hi2)
			return ((u64int)hi << 32) | lo;
	}
}

/*
 * The ARM-side timer, used purely as a software-triggered interrupt.
 *
 * usbdwc.c needs somewhere safe to finish work the USB interrupt
 * started: upstream runs that interrupt as an FIQ, where taking the
 * locks wakeup() needs is not allowed, so it arms this timer and does
 * the wakeups from the ordinary interrupt that follows. Keeping the
 * mechanism means the driver stays diffable against Plan 9 rather than
 * being restructured around this port's lack of FIQ support.
 */
typedef struct Armtimer Armtimer;
struct Armtimer
{
	u32int	load;
	u32int	val;
	u32int	ctl;
	u32int	irqack;
	u32int	irq;
	u32int	maskedirq;
	u32int	reload;
	u32int	predivider;
	u32int	count;
};

/* volatile: Device memory, and adjacent stores must not be merged. */
#define ARMTIMER	((volatile Armtimer*)(uintptr)ARMTIMERREGS)

void
armtimerset(int n)
{
	volatile Armtimer *tm;

	tm = ARMTIMER;
	if(n > 0){
		tm->ctl |= TmrEnable|TmrIntEnable;
		tm->load = n;
	}else{
		tm->load = 0;
		tm->ctl &= ~(TmrEnable|TmrIntEnable);
		tm->irqack = 1;
	}
	coherence();
}
