/*
 * The console: RP1's UART0 on GPIO14/15, a PL011 the firmware has
 * already set to 115200 (enable_rp1_uart). Its pins and clock are left
 * alone. Output is polled, as every console's is; input arrives by
 * interrupt.
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
#define R10(r)	(*(volatile u32int*)(uintptr)(UART10 + (r)))

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
/*
 * And on the 3-pin debug connector: uart10, on the SoC itself, which
 * the firmware leaves at 115200 and which needs nothing of PCIe. It is
 * what will still talk when RP1 does not. Output only by default: with
 * nothing plugged in, its receiver fills with noise that would be typed
 * at the shell. uart10rx=1 on the command line (cmdline.txt) reads it
 * too, for a board whose only cable is a Debug Probe on that connector.
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
	for(i = 0; (R10(Fr) & Txff) != 0 && i < Txspin; i++)
		;
	R10(Dr) = c;
}

/*
 * Whether miniputc can go without waiting, for ../bcm/uart.c's process
 * writer, which waits for this with interrupts on.
 */
int
minitxrdy(void)
{
	return ((R(Fr) | R4(Fr) | R10(Fr)) & Txff) == 0;
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
rxinterrupt(Ureg*, void *arg)
{
	uintptr b;
	volatile u32int *u;

	b = (uintptr)arg;
	u = (u32int*)b;
	while((u[Fr/4] & Rxfe) == 0)
		consuartputc(nil, u[Dr/4] & 0xFF);
}

/*
 * uart10's input, polled: its interrupt is the SoC's, not RP1's, and a
 * console typed at by hand needs no more than a look every 10 ms (the
 * FIFO holds 32 characters, 2.7 ms at 115200; pasted text loses what
 * overflows, as a terminal's would)
 */
static void
uart10poll(void)
{
	while((R10(Fr) & Rxfe) == 0)
		consuartputc(nil, R10(Dr) & 0xFF);
}

static int
cmdflag(char *name)
{
	char *p, *q;
	int n;

	p = boardcmdline();
	n = strlen(name);
	for(q = p; q != nil && (q = strstr(q, name)) != nil; q += n)
		if((q == p || q[-1] == ' ') && strncmp(q+n, "=1", 2) == 0 && (q[n+2] == 0 || q[n+2] == ' ' || q[n+2] == '\n'))
			return 1;
	return 0;
}

void
rp1uartlink(void)
{
	if(cmdflag("uart10rx")){
		while((R10(Fr) & Rxfe) == 0)
			(void)R10(Dr);		/* what came before it was asked for */
		addclock0link(uart10poll, 10);
		print("uart10: console input on the debug connector\n");
	}
	rp1intrenable(RP1intuart0, rxinterrupt, (void*)(uintptr)RP1UART0, 1, "uart0");
	rp1intrenable(RP1intuart4, rxinterrupt, (void*)(uintptr)RP1UART4, 1, "uart4");
	R(Imsc) |= Imrx | Imrt;
	R4(Imsc) |= Imrx | Imrt;
	coherence();
}
