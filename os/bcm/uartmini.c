/*
 * The BCM2835 mini-UART (UART1, on the AUX block): the console.
 *
 * From 9front's sys/src/9/bcm/uartmini.c (MIT), which is also how
 * Plan 9 boots a Pi 3: the console on the mini-UART at GPIO 14/15 on
 * ALT5, so that the PL011 is free for the radio it is wired to (see
 * docs/BLUETOOTH.md). Two halves live here. The PhysUart is what #t
 * (os/port/devuart.c) drives, interrupt-fed, as /dev/eia1. The polled
 * routines at the bottom are the early console that uart.c wraps:
 * they run before there are interrupts, before the MMU, and inside
 * panic, and they never wait on anything but the FIFO.
 *
 * What differs from 9front, and why:
 *
 * - The pin mux goes through gpio.c, and the pins are CLAIMED, so #G
 *   refuses to move the console's pins from under it (devgpio.c).
 * - The clock is asked for, not assumed. The mini-UART's divisor is
 *   derived from the VPU core clock, which the firmware scales unless
 *   config.txt pins it; 9front hardcodes 250MHz and relies on
 *   enable_uart=1 doing the pinning. This driver asks the mailbox for
 *   the core rate before it prints a character -- nothing printed with
 *   the wrong divisor can be read, so the order is forced -- and falls
 *   back to 250MHz only if the firmware will not say. The rate it used
 *   is the first thing it prints, so a garbled console at least has a
 *   number to argue with once a cable is moved to the right baud.
 * - No OkLed. The LED is a pin in #G (INFR-455) and a program's business.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"
#include "../port/error.h"
#include "../port/uart.h"

enum {
	TxPin		= 14,
	RxPin		= 15,
	Corefallback	= 250000000,	/* what enable_uart=1 pins core_freq to */
	Txspin		= 1000000,	/* bounded wait for FIFO room, as uart.c */
};

#define AUX	((volatile u32int*)(uintptr)AUXREGS)

extern PhysUart miniphysuart;

static Uart miniuart = {
	.regs	= (void*)(uintptr)AUXREGS,
	.name	= "uart1",
	.freq	= Corefallback,
	.baud	= 115200,
	.bits	= 8,
	.stop	= 1,
	.parity	= 'n',	/* so status reads sensibly before the first open */
	.phys	= &miniphysuart,
	.console= 1,
	.putc	= consuartputc,		/* uart.c: CR->NL, echo, kbdputc */
};

static int baud(Uart*, int);

/*
 * Two sources share IRQaux: SPI1 and SPI2 are the others, and neither
 * is enabled here, so anything pending is ours.
 */
static void
interrupt(Ureg*, void *arg)
{
	Uart *uart;
	volatile u32int *ap;

	uart = arg;
	ap = uart->regs;

	coherence();
	if(ap[Mulsr] & Mutxrdy)
		uartkick(uart);
	if(ap[Mulsr] & Murxrdy){
		do{
			uartrecv(uart, ap[Muio] & 0xFF);
		}while(ap[Mulsr] & Murxrdy);
	}
	coherence();
}

static Uart*
pnp(void)
{
	return &miniuart;
}

/*
 * Bring the port up on GPIO 14/15. Idempotent, and it has to be: the
 * polled console below runs this from uartinit() long before #t's
 * reset calls it again with interrupts wanted, and the second call
 * must not glitch a line the boot log is already coming out of.
 */
static void
enable(Uart *uart, int ie)
{
	volatile u32int *ap;
	long i;

	ap = uart->regs;
	gpiofunc(TxPin, Gpioalt5);
	gpiofunc(RxPin, Gpioalt5);
	gpiopull(TxPin, Pullnone);
	gpiopull(RxPin, Pullup);
	gpioclaim(TxPin, "uart");
	gpioclaim(RxPin, "uart");
	/*
	 * Second time through -- #t enabling what uartinit() already
	 * runs -- the transmit FIFO may hold the tail of a boot line, and
	 * the FIFO clear below would eat it. Let it drain first. QEMU's
	 * FIFO is always empty; the board's holds eight characters.
	 */
	if(ap[Auxenables] & Auxuarten)
		for(i = 0; (ap[Mulsr] & Mutxdone) == 0 && i < Txspin; i++)
			;
	ap[Auxenables] |= Auxuarten;
	ap[Muiir] = 6;			/* clear both FIFOs */
	ap[Mulcr] = Mubits8;
	ap[Mucntl] = Mutxen|Murxen;
	baud(uart, uart->baud);
	if(ie){
		intrenable(IRQaux, interrupt, uart, 0, uart->name);
		ap[Muier] = Murxien|Mutxien;
	}else
		ap[Muier] = 0;
}

static void
disable(Uart *uart)
{
	volatile u32int *ap;

	ap = uart->regs;
	ap[Mucntl] = 0;
	ap[Muier] = 0;
}

static void
kick(Uart *uart)
{
	volatile u32int *ap;

	coherence();
	ap = uart->regs;
	while(ap[Mulsr] & Mutxrdy){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		ap[Muio] = *(uart->op++);
	}
	if(ap[Mulsr] & Mutxdone)
		ap[Muier] &= ~Mutxien;
	else
		ap[Muier] |= Mutxien;
	coherence();
}

/* the mini-UART has no break generator */
static void
dobreak(Uart*, int)
{
}

/*
 * baud = core_clk / (8 * (divisor + 1)), rounded to nearest. At 250MHz
 * and 115200 the divisor is 270 and the rate 115313, 0.1% out.
 */
static int
baud(Uart *uart, int n)
{
	volatile u32int *ap;

	ap = uart->regs;
	if(uart->freq == 0 || n <= 0)
		return -1;
	ap[Mubaud] = (uart->freq + 4*n - 1) / (8 * n) - 1;
	uart->baud = n;
	return 0;
}

static int
bits(Uart *uart, int n)
{
	volatile u32int *ap;
	int set;

	ap = uart->regs;
	switch(n){
	case 7:
		set = Mubits7;
		break;
	case 8:
		set = Mubits8;
		break;
	default:
		return -1;
	}
	ap[Mulcr] = (ap[Mulcr] & ~Mubitsmask) | set;
	uart->bits = n;
	return 0;
}

static int
stop(Uart *uart, int n)
{
	if(n != 1)
		return -1;
	uart->stop = n;
	return 0;
}

static int
parity(Uart *uart, int n)
{
	if(n != 'n')
		return -1;
	uart->parity = n;
	return 0;
}

/*
 * cts/rts flow control. The signals are not on the header on a Pi 3
 * (GPIO 16/17 on ALT5 would carry them), so this is here for the
 * interface and nothing routes them; the console has never needed it.
 */
static void
modemctl(Uart *uart, int on)
{
	volatile u32int *ap;

	ap = uart->regs;
	if(on)
		ap[Mucntl] |= Muctsflow;
	else
		ap[Mucntl] &= ~Muctsflow;
	uart->modem = on;
}

static void
rts(Uart *uart, int on)
{
	volatile u32int *ap;

	ap = uart->regs;
	if(on)
		ap[Mumcr] &= ~Murtsn;
	else
		ap[Mumcr] |= Murtsn;
}

static void
donothing(Uart*, int)
{
}

static long
status(Uart *uart, void *buf, long n, long offset)
{
	char *p;

	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	snprint(p, READSTR,
		"b%d c%d d%d e%d l%d m%d p%c r%d s%d\n"
		"dev(%d) type(%d) framing(%d) overruns(%d) "
		"berr(%d) serr(%d) freq(%lud)\n",
		uart->baud, uart->hup_dcd, uart->dsr, uart->hup_dsr,
		uart->bits, uart->modem, uart->parity, uart->cts, uart->stop,
		uart->dev, uart->type, uart->ferr, uart->oerr,
		uart->berr, uart->serr, uart->freq);
	n = readstr(offset, buf, n, p);
	free(p);
	return n;
}

static void
putc(Uart*, int c)
{
	volatile u32int *ap;
	long i;

	ap = AUX;
	for(i = 0; (ap[Mulsr] & Mutxrdy) == 0; i++)
		if(i >= Txspin)
			return;
	ap[Muio] = c;
}

static int
getc(Uart*)
{
	volatile u32int *ap;

	ap = AUX;
	if((ap[Mulsr] & Murxrdy) == 0)
		return -1;
	return ap[Muio] & 0xFF;
}

PhysUart miniphysuart = {
	.name		= "mini",
	.pnp		= pnp,
	.enable		= enable,
	.disable	= disable,
	.kick		= kick,
	.dobreak	= dobreak,
	.baud		= baud,
	.bits		= bits,
	.stop		= stop,
	.parity		= parity,
	.modemctl	= modemctl,
	.rts		= rts,
	.dtr		= donothing,
	.fifo		= donothing,
	.status		= status,
	.getc		= getc,
	.putc		= putc,
};

/*
 * The polled early console, for uart.c.
 *
 * miniconsinit() asks the firmware for the core clock first and only
 * then enables the port, for the reason in the header: a divisor from
 * the wrong clock makes every later character unreadable, including
 * the one that would have said so. It returns the rate it used so the
 * caller can print it -- readably, now.
 */
ulong
miniconsinit(void)
{
	u32int hz;

	hz = mboxclockrate(Clkcore);
	if(hz == 0)
		hz = Corefallback;
	miniuart.freq = hz;
	enable(&miniuart, 0);
	return hz;
}

void
miniputc(int c)
{
	putc(&miniuart, c);
}

int
minigetc(void)
{
	return getc(&miniuart);
}

/*
 * Does the transmitter still hold anything? For uart.c's drain before
 * the console changes hands or the machine resets.
 */
int
minitxidle(void)
{
	return (AUX[Mulsr] & Mutxdone) != 0;
}
