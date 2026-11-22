/*
 * What the family's shared files call that this board has no block
 * for: no DWC OTG on the host side, no second UART, and no timers.c,
 * whose ARM timer is at the old window.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "../port/uart.h"

PhysUart miniphysuart;		/* no second port: its pnp is nil */

void	usbdwclink(void) {}

u64int
systimer(void)
{
	volatile u32int *st;
	u32int hi, lo;

	st = (u32int*)(uintptr)SYSTIMERREGS;
	do{
		hi = st[Stchi/4];
		lo = st[Stclo/4];
	}while(hi != st[Stchi/4]);
	return (u64int)hi << 32 | lo;
}
