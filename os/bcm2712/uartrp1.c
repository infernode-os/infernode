/*
 * The console: RP1's UART0 on GPIO14/15, a PL011 the firmware has
 * already set to 115200 (enable_rp1_uart). Its pins and clock are left
 * alone. Output is polled, as every console's is; input is polled from
 * the clock, because RP1's interrupts need the MSI path, which comes
 * with the rest of RP1. At 115200 the 32-byte FIFO lasts 2.7ms.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define R(r)	(*(volatile u32int*)(uintptr)(RP1UART0 + (r)))
#define R4(r)	(*(volatile u32int*)(uintptr)(RP1UART4 + (r)))

enum
{
	Txspin	= 1000000,

	/* 115200 from RP1's 48MHz UART clock: 26 and 3/64 */
	Ibrdval	= 26,
	Fbrdval	= 3,
};

/*
 * And the same on UART4, GPIO 12 and 13, header pins 32 and 33. An
 * M.2 board sits on pins 1-12 and takes the usual ones away; this way
 * the console is on both, and moving the cable needs no new kernel.
 * The firmware's own log stays on GPIO 14 and 15.
 */
ulong
miniconsinit(void)
{
	R4(Cr) = 0;
	R4(Ibrd) = Ibrdval;
	R4(Fbrd) = Fbrdval;
	R4(Lcrh) = Fen | Wlen8;
	R4(Imsc) = 0;
	R4(Cr) = Uarten | Txe | Rxe;
	gpiofunc(12, Gpioalt2);
	gpiofunc(13, Gpioalt2);
	gpiopull(13, Pullup);
	return 48000000;
}

void
miniputc(int c)
{
	int i;

	for(i = 0; (R(Fr) & Txff) != 0 && i < Txspin; i++)
		;
	R(Dr) = c;
	for(i = 0; (R4(Fr) & Txff) != 0 && i < Txspin; i++)
		;
	R4(Dr) = c;
}

int
minigetc(void)
{
	if((R(Fr) & Rxfe) == 0)
		return R(Dr) & 0xFF;
	if((R4(Fr) & Rxfe) == 0)
		return R4(Dr) & 0xFF;
	return -1;
}

static void
rxpoll(void)
{
	while((R(Fr) & Rxfe) == 0)
		consuartputc(nil, R(Dr) & 0xFF);
	while((R4(Fr) & Rxfe) == 0)
		consuartputc(nil, R4(Dr) & 0xFF);
}

void
rp1uartlink(void)
{
	addclock0link(rxpoll, 1);
}
