/*
 * The PL011 as a PhysUart: /dev/eia0, and the console.
 *
 * This is os/bcm2837/uartpl011.c with the board taken out of it. There
 * the PL011 is the radio's HCI line, muxed onto GPIO 30-33 and clocked
 * at a rate the firmware has to be asked for; here it is the only UART
 * there is, it has no pins to mux, its clock is the fixed 24MHz in
 * virt's device tree, and it is the console -- so received bytes go
 * through consuartputc (uart.c) to kbdq, as the mini-UART's do on the
 * board.
 *
 * The register code is unchanged, flow control and error counting
 * included: QEMU's model has no wire to overrun, but the driver is the
 * one a real PL011 console would want, and keeping it whole keeps it
 * diffable against the board's. The two should become one file in
 * os/arm64 with the pins and the clock behind a hook.
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
	Uartclk		= 24000000,	/* virt's "apb-pclk" */
	Txspin		= 1000000,
};

#define R(u, r)	(*(volatile u32int*)((uintptr)(u)->regs + (r)))

extern PhysUart pl011physuart;

static Uart pl011uart = {
	.regs	= (void*)(uintptr)UART0REGS,
	.name	= "uart0",
	.freq	= Uartclk,
	.baud	= 115200,
	.bits	= 8,
	.stop	= 1,
	.parity	= 'n',	/* so status reads sensibly before the first open */
	.phys	= &pl011physuart,
	.console= 1,
	.putc	= consuartputc,		/* uart.c: CR->NL, echo, kbdputc */
};

static ulong nintr, nrx, ntx;	/* interrupts taken, bytes in, bytes out; one PL011, so one set */

static int baud(Uart*, int);

static Uart*
pnp(void)
{
	return &pl011uart;
}

static void
interrupt(Ureg*, void *arg)
{
	Uart *uart;
	u32int d, mis;

	uart = arg;
	coherence();
	nintr++;
	mis = R(uart, Mis);
	while((R(uart, Fr) & Rxfe) == 0){
		d = R(uart, Dr);
		nrx++;
		if(d & Rxerrors){
			if(d & Rxfe_err)
				uart->ferr++;
			if(d & Rxpe_err)
				uart->perr++;
			if(d & Rxoe_err)
				uart->oerr++;
			R(uart, Rsrecr) = 0;
			if(d & Rxbe_err)
				continue;	/* a break is not a byte */
		}
		uartrecv(uart, d & 0xFF);
	}
	if(mis & Imtx)
		uartkick(uart);
	/* RX/RT clear themselves with the FIFO; the rest are cleared here */
	R(uart, Icr) = mis & (Imtx|Imrxerr|Imcts);
	coherence();
}

static void
uartoff(Uart *uart)
{
	long i;

	R(uart, Imsc) = 0;
	/* let the shifter finish: reconfiguring mid-character corrupts it */
	for(i = 0; (R(uart, Fr) & Frbusy) && i < Txspin; i++)
		;
	R(uart, Cr) = 0;
	coherence();
}

/*
 * The transmit interrupt is LEVEL: TXI is asserted for as long as the
 * FIFO is at or below its trigger, which with nothing to send is for
 * ever. So it is not enabled here; kick() unmasks it when it leaves
 * bytes behind in the queue and masks it when it has drained them,
 * the way the mini-UART driver handles its TxIen. Enabled unmasked, it
 * would take the core the moment interrupts were on and never give it
 * back -- QEMU's model asserts it once and would not have shown this.
 */
static void
uarton(Uart *uart, int ie)
{
	u32int cr;

	R(uart, Icr) = 0x7FF;
	R(uart, Ifls) = Rxiflsel1_8 | Txiflsel1_8;
	cr = Uarten | Txe | Rxe;
	if(uart->modem)
		cr |= Crrtsen | Crctsen;
	R(uart, Cr) = cr;
	coherence();
	if(ie)
		R(uart, Imsc) = Imrx | Imrt | Imrxerr;
}

static void
enable(Uart *uart, int ie)
{
	uartoff(uart);
	R(uart, Lcrh) = (R(uart, Lcrh) & ~Wlenmask) | Fen | Wlen8;
	/*
	 * Program the divisors for the rate we claim, rather than trust
	 * what is in them: on the board that is whatever serialboot left
	 * (115200, as it happens), under QEMU nothing at all.
	 */
	baud(uart, uart->baud);
	if(ie)
		intrenable(IRQuart, interrupt, uart, 0, uart->name);
	uarton(uart, ie);
}

static void
disable(Uart *uart)
{
	uartoff(uart);
	R(uart, Icr) = 0x7FF;
	R(uart, Lcrh) &= ~Fen;		/* flush the FIFOs */
	coherence();
}

static void
linectl(Uart *uart, u32int set, u32int clr)
{
	int on;

	on = uart->enabled;
	if(on)
		uartoff(uart);
	R(uart, Lcrh) = set | (R(uart, Lcrh) & ~clr);
	if(on)
		uarton(uart, 1);
}

static void
kick(Uart *uart)
{
	int more;

	coherence();
	more = 1;
	while((R(uart, Fr) & Txff) == 0){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0){
			more = 0;
			break;
		}
		R(uart, Dr) = *(uart->op++);
		ntx++;
	}
	/* see uarton: the transmit interrupt is on only while there is more */
	if(more)
		R(uart, Imsc) |= Imtx;
	else
		R(uart, Imsc) &= ~Imtx;
	coherence();
}

static void
dobreak(Uart *uart, int ms)
{
	linectl(uart, Lcrbrk, 0);
	microdelay(ms*1000);
	linectl(uart, 0, Lcrbrk);
}

/*
 * divisor = freq / (16 * baud); IBRD is its integer part, FBRD the
 * fraction in 64ths. The PL011 latches both when LCRH is written, so
 * linectl's rewrite of LCRH below is what makes them take.
 */
static int
baud(Uart *uart, int n)
{
	u32int div64, ibrd, fbrd;
	int on;

	if(uart->freq == 0 || n <= 0)
		return -1;
	div64 = (u32int)(((uvlong)uart->freq * 4 + n/2) / n);	/* 64 * freq/(16n) */
	ibrd = div64 >> 6;
	fbrd = div64 & 63;
	if(ibrd == 0 || ibrd > 0xFFFF)
		return -1;
	on = uart->enabled;
	if(on)
		uartoff(uart);
	R(uart, Ibrd) = ibrd;
	R(uart, Fbrd) = fbrd;
	R(uart, Lcrh) = R(uart, Lcrh);	/* latch */
	if(on)
		uarton(uart, 1);
	uart->baud = n;
	return 0;
}

static int
bits(Uart *uart, int n)
{
	switch(n){
	case 8:
		linectl(uart, Wlen8, Wlenmask);
		break;
	case 7:
		linectl(uart, Wlen7, Wlenmask);
		break;
	case 6:
		linectl(uart, Wlen6, Wlenmask);
		break;
	case 5:
		linectl(uart, Wlen5, Wlenmask);
		break;
	default:
		return -1;
	}
	uart->bits = n;
	return 0;
}

static int
stop(Uart *uart, int n)
{
	switch(n){
	case 1:
		linectl(uart, 0, Lcrstp2);
		break;
	case 2:
		linectl(uart, Lcrstp2, 0);
		break;
	default:
		return -1;
	}
	uart->stop = n;
	return 0;
}

static int
parity(Uart *uart, int n)
{
	switch(n){
	case 'n':
		linectl(uart, 0, Lcrpen);
		break;
	case 'e':
		linectl(uart, Lcreps|Lcrpen, 0);
		break;
	case 'o':
		linectl(uart, Lcrpen, Lcreps);
		break;
	default:
		return -1;
	}
	uart->parity = n;
	return 0;
}

/*
 * Hardware flow control, both directions: the receiver drops RTS when
 * its FIFO is at the watermark, the transmitter waits for CTS.
 */
static void
modemctl(Uart *uart, int on)
{
	uart->modem = on;
	if(!uart->enabled)
		return;
	if(on)
		R(uart, Cr) |= Crrtsen | Crctsen;
	else
		R(uart, Cr) &= ~(Crrtsen | Crctsen);
	coherence();
}

/* manual RTS, meaningful only with modemctl off; devuart uses it for flow */
static void
rts(Uart *uart, int on)
{
	if(uart->modem)
		return;
	if(on)
		R(uart, Cr) |= Crrts;
	else
		R(uart, Cr) &= ~Crrts;
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
	/*
	 * The third and fourth lines are the hardware and the path as
	 * they stand: the raw flag, control, interrupt-mask and
	 * raw-interrupt-status registers, the divisors, and how many
	 * bytes passed each hop -- the interrupt handler, the staging
	 * buffer into the queue, the queue into readers. Together they
	 * separate "the peer said nothing" from "it spoke and no
	 * interrupt came" from "it arrived and someone else read it",
	 * which is how the first board session found two bt9p instances
	 * sharing one port. QEMU cannot tell those apart for us.
	 */
	snprint(p, READSTR,
		"b%d c%d d%d e%d l%d m%d p%c r%d s%d\n"
		"dev(%d) type(%d) framing(%d) overruns(%d) parity(%d) "
		"berr(%d) serr(%d) freq(%lud) clock(%s) cts(%d)\n"
		"fr(0x%ux) cr(0x%ux) imsc(0x%ux) ris(0x%ux) ibrd(%ud) fbrd(%ud) intrs(%lud) rx(%lud) tx(%lud)\n"
		"staged(%lud) read(%lud) clocks(%lud) qlen(%d) enabled(%d)\n",
		uart->baud, uart->hup_dcd, uart->dsr, uart->hup_dsr,
		uart->bits, uart->modem, uart->parity, uart->cts, uart->stop,
		uart->dev, uart->type, uart->ferr, uart->oerr, uart->perr,
		uart->berr, uart->serr, uart->freq,
		"fixed",
		(R(uart, Fr) & Frcts) != 0,
		R(uart, Fr), R(uart, Cr), R(uart, Imsc), R(uart, Ris), R(uart, Ibrd), R(uart, Fbrd),
		nintr, nrx, ntx,
		uart->nstaged, uart->nread, uart->nclock, uart->iq != nil ? qlen(uart->iq) : -1, uart->enabled);
	n = readstr(offset, buf, n, p);
	free(p);
	return n;
}

static void
putc(Uart *uart, int c)
{
	long i;

	for(i = 0; R(uart, Fr) & Txff; i++)
		if(i >= Txspin)
			return;
	R(uart, Dr) = c & 0xFF;
}

static int
getc(Uart *uart)
{
	u32int d;

	if(R(uart, Fr) & Rxfe)
		return -1;
	d = R(uart, Dr);
	if(d & Rxerrors)
		R(uart, Rsrecr) = 0;
	return d & 0xFF;
}

PhysUart pl011physuart = {
	.name		= "pl011",
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
