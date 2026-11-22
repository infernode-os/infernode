/*
 * /dev/eia0: the Bluetooth half of the radio, on the SoC's Broadcom
 * UART, a 16550 with its registers a word apart and a 96MHz clock
 * (Linux's bcm2712-rpi-5-b.dts). bt9p opens it by that name on every
 * board. On a Pi 3 or 4 the same job is ../bcm/uartpl011.c's, and this
 * has its name so that ../bcm/uart.c's table needs no change.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "../port/error.h"
#include "../port/uart.h"

extern PhysUart pl011physuart;

#define R(r)	(*(volatile u32int*)(uintptr)(0x107D50C000ULL + 4*(r)))

enum
{
	Clock	= 96000000,
	IRQbt	= IRQspi + 276,

	Rbr	= 0,
	Thr	= 0,
	Dll	= 0,
	Ier	= 1,
	Dlm	= 1,
	Iir	= 2,
	Fcr	= 2,
	Lcr	= 3,
	Mcr	= 4,
	Lsr	= 5,

	Irx	= 1<<0,
	Itx	= 1<<1,
	Ils	= 1<<2,

	Fifoen	= 1<<0,
	Fiforst	= 3<<1,
	Fifotrig= 2<<6,		/* interrupt at half full */

	Dlab	= 1<<7,
	Brk	= 1<<6,
	Pen	= 1<<3,
	Eps	= 1<<4,
	Stb	= 1<<2,

	Dtr	= 1<<0,
	Rts	= 1<<1,
	Out2	= 1<<3,
	Afe	= 1<<5,		/* RTS and CTS by the hardware */

	Ldr	= 1<<0,
	Oe	= 1<<1,
	Pe	= 1<<2,
	Fe	= 1<<3,
	Bi	= 1<<4,
	Thre	= 1<<5,

	Fifosize= 16,
	Txspin	= 1000000,
};

static Uart btuart = {
	.name	= "uart0",
	.freq	= Clock,
	.baud	= 115200,
	.bits	= 8,
	.stop	= 1,
	.parity	= 'n',
	.phys	= &pl011physuart,
};

static ulong nintr, nrx, ntx;

static int	baud(Uart*, int);

static Uart*
pnp(void)
{
	return &btuart;
}

static void
rxhold(Uart *uart, int on)
{
	ilock(&uart->tlock);
	uart->rxheld = on;
	if(on){
		uart->nhold++;
		R(Ier) &= ~(u32int)(Irx|Ils);
	}else
		R(Ier) |= Irx|Ils;
	coherence();
	iunlock(&uart->tlock);
}

static void
kick(Uart *uart)
{
	int i;

	coherence();
	if(R(Lsr) & Thre){
		for(i = 0; i < Fifosize; i++){
			if(uart->op >= uart->oe && uartstageoutput(uart) == 0){
				R(Ier) &= ~(u32int)Itx;
				coherence();
				return;
			}
			R(Thr) = *(uart->op++);
			ntx++;
		}
	}
	R(Ier) |= Itx;
	coherence();
}

static void
interrupt(Ureg*, void *arg)
{
	Uart *uart;
	u32int l;

	uart = arg;
	nintr++;
	(void)R(Iir);
	for(;;){
		l = R(Lsr);
		if((l & Ldr) == 0)
			break;
		if(uart->modem && !uartroom(uart)){
			rxhold(uart, 1);
			break;
		}
		if(l & Fe)
			uart->ferr++;
		if(l & Pe)
			uart->perr++;
		if(l & Oe)
			uart->oerr++;
		nrx++;
		uartrecv(uart, R(Rbr) & 0xFF);
	}
	if(l & Thre)
		uartkick(uart);
	coherence();
}

static void
enable(Uart *uart, int ie)
{
	static int linked;

	btpins();
	R(Ier) = 0;
	R(Fcr) = Fifoen | Fiforst | Fifotrig;
	R(Lcr) = 3;			/* 8 bits, no parity, one stop */
	R(Mcr) = Dtr | Rts | Out2 | (uart->modem ? Afe : 0);
	baud(uart, uart->baud);
	uart->rxheld = 0;
	if(ie){
		if(!linked){
			linked = 1;
			intrenable(IRQbt, interrupt, uart, 0, uart->name);
		}
		R(Ier) = Irx | Ils;
	}
	coherence();
}

static void
disable(Uart*)
{
	R(Ier) = 0;
	coherence();
}

static void
dobreak(Uart*, int ms)
{
	R(Lcr) |= Brk;
	microdelay(ms*1000);
	R(Lcr) &= ~(u32int)Brk;
}

static int
baud(Uart *uart, int n)
{
	u32int d, l;

	if(n <= 0)
		return -1;
	d = (Clock + 8*n) / (16*n);
	if(d == 0 || d > 0xFFFF)
		return -1;
	l = R(Lcr);
	R(Lcr) = l | Dlab;
	R(Dll) = d & 0xFF;
	R(Dlm) = d >> 8;
	R(Lcr) = l;
	coherence();
	uart->baud = n;
	return 0;
}

static int
bits(Uart *uart, int n)
{
	if(n < 5 || n > 8)
		return -1;
	R(Lcr) = (R(Lcr) & ~(u32int)3) | (n - 5);
	uart->bits = n;
	return 0;
}

static int
stop(Uart *uart, int n)
{
	if(n != 1 && n != 2)
		return -1;
	if(n == 2)
		R(Lcr) |= Stb;
	else
		R(Lcr) &= ~(u32int)Stb;
	uart->stop = n;
	return 0;
}

static int
parity(Uart *uart, int c)
{
	u32int l;

	l = R(Lcr) & ~(u32int)(Pen|Eps);
	switch(c){
	case 'n':	break;
	case 'o':	l |= Pen; break;
	case 'e':	l |= Pen|Eps; break;
	default:	return -1;
	}
	R(Lcr) = l;
	uart->parity = c;
	return 0;
}

static void
modemctl(Uart *uart, int on)
{
	uart->modem = on;
	if(on)
		R(Mcr) |= Afe;
	else
		R(Mcr) &= ~(u32int)Afe;
}

static void
rts(Uart *uart, int on)
{
	if(uart->modem)
		return;
	if(on)
		R(Mcr) |= Rts;
	else
		R(Mcr) &= ~(u32int)Rts;
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
		"dev(%d) type(%d) framing(%d) overruns(%d) parity(%d) freq(%lud)\n"
		"lsr(0x%ux) mcr(0x%ux) ier(0x%ux) intrs(%lud) rx(%lud) tx(%lud)\n",
		uart->baud, uart->hup_dcd, uart->dsr, uart->hup_dsr,
		uart->bits, uart->modem, uart->parity, uart->cts, uart->stop,
		uart->dev, uart->type, uart->ferr, uart->oerr, uart->perr, uart->freq,
		R(Lsr), R(Mcr), R(Ier), nintr, nrx, ntx);
	n = readstr(offset, buf, n, p);
	free(p);
	return n;
}

static void
putc(Uart*, int c)
{
	long i;

	for(i = 0; (R(Lsr) & Thre) == 0 && i < Txspin; i++)
		;
	R(Thr) = c & 0xFF;
}

static int
getc(Uart*)
{
	if((R(Lsr) & Ldr) == 0)
		return -1;
	return R(Rbr) & 0xFF;
}

PhysUart pl011physuart = {
	.name		= "bcm7271",
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
	.rxhold		= rxhold,
};
