/*
 * The console: a 16550-compatible UART, the part both RISC-V machines
 * this kernel runs on have. QEMU's virt has an NS16550A with byte-wide
 * registers a byte apart; a PolarFire SoC's MMUART is 16550-compatible
 * with 32-bit registers four bytes apart. The board's io.h says which:
 *
 *	UARTREGS	base address
 *	UARTSHIFT	log2 of the register stride
 *	UARTWIDE	1 if registers must be accessed 32 bits wide
 *	UARTCLK		the input clock, Hz; 0 leaves the firmware's divisor
 *	UARTIRQ		its PLIC interrupt
 *
 * Two halves, as ../virt/uart.c and uartpl011.c are for the PL011: the
 * polled console the whole kernel prints through from the first
 * instruction (uartputc and the policy above it), and a PhysUart for
 * os/port/devuart.c, which from #t's reset delivers received bytes by
 * interrupt to kbdq through consuartputc.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "../port/uart.h"

enum
{
	Rbr	= 0,	/* receive buffer (read) */
	Thr	= 0,	/* transmit holding (write) */
	Dll	= 0,	/* divisor latch low (LCR.DLAB) */
	Ier	= 1,	/* interrupt enable */
	Dlm	= 1,	/* divisor latch high (LCR.DLAB) */
	Iir	= 2,	/* interrupt identification (read) */
	Fcr	= 2,	/* FIFO control (write) */
	Lcr	= 3,	/* line control */
	Mcr	= 4,	/* modem control */
	Lsr	= 5,	/* line status */
	Msr	= 6,	/* modem status */

	Erda	= 1<<0,		/* IER: received data available */
	Ethre	= 1<<1,		/* IER: transmit holding empty */
	Erls	= 1<<2,		/* IER: line status */

	Fena	= 1<<0,		/* FCR: FIFOs on */
	Frclr	= 1<<1,
	Ftclr	= 1<<2,

	Wls8	= 3<<0,		/* LCR: 8 bits */
	Stb	= 1<<2,		/* LCR: two stop bits */
	Pen	= 1<<3,		/* LCR: parity */
	Eps	= 1<<4,		/* LCR: even parity */
	Brk	= 1<<6,
	Dlab	= 1<<7,

	Dtr	= 1<<0,		/* MCR */
	Rts	= 1<<1,
	Out2	= 1<<3,		/* gates the interrupt line on PC-style parts */

	Dr	= 1<<0,		/* LSR: data ready */
	Oe	= 1<<1,
	Pe	= 1<<2,
	Fe	= 1<<3,
	Bi	= 1<<4,
	Thre	= 1<<5,		/* transmit holding register empty */

	Baud	= 115200,
	Txspin	= 1000000,
};

static uintptr
ureg(uintptr base, int r)
{
	return base + ((uintptr)r << UARTSHIFT);
}

static u32int
rd(uintptr base, int r)
{
	if(UARTWIDE)
		return *(volatile u32int*)ureg(base, r);
	return *(volatile uchar*)ureg(base, r);
}

static void
wr(uintptr base, int r, u32int v)
{
	if(UARTWIDE)
		*(volatile u32int*)ureg(base, r) = v;
	else
		*(volatile uchar*)ureg(base, r) = v;
}

/*
 * The console: the board's UARTREGS and UARTIRQ unless it moves it
 * (uartconsole) once it has read the device tree.
 */
static uintptr	consbase = UARTREGS;
static int	consirq = UARTIRQ;

#define	CONS	consbase

static void
setdivisor(uintptr base, ulong freq, int baud)
{
	ulong div;
	u32int lcr;

	if(freq == 0 || baud <= 0)
		return;
	div = (freq + 8*baud) / (16*baud);
	if(div == 0 || div > 0xFFFF)
		return;
	lcr = rd(base, Lcr);
	wr(base, Lcr, lcr | Dlab);
	wr(base, Dll, div & 0xFF);
	wr(base, Dlm, div >> 8);
	wr(base, Lcr, lcr & ~Dlab);
}

void
uartinit(void)
{
	wr(CONS, Ier, 0);
	/*
	 * The firmware has the console running already (OpenSBI printed
	 * its banner through it); reprogram only when the board knows the
	 * clock, so a wrong guess cannot turn the console to noise.
	 */
	if(UARTCLK != 0){
		wr(CONS, Lcr, Wls8);
		setdivisor(CONS, UARTCLK, Baud);
	}
	wr(CONS, Fcr, Fena | Frclr | Ftclr);
	wr(CONS, Mcr, Dtr | Rts | Out2);
}

char*
uartdescribe(void)
{
	static char buf[80];

	snprint(buf, sizeof buf, "16550 at %#p, polled; %s",
		(void*)consbase, UARTCLK != 0 ? "115200 baud" : "firmware's rate");
	return buf;
}

void
uartputc(int c)
{
	long i;

	for(i = 0; (rd(CONS, Lsr) & Thre) == 0; i++)
		if(i >= Txspin)
			return;
	wr(CONS, Thr, c & 0xFF);
}

int
uartgetc(void)
{
	if((rd(CONS, Lsr) & Dr) == 0)
		return -1;
	return rd(CONS, Rbr) & 0xFF;
}

/*
 * A received byte, from #t's interrupt path: the console's line
 * discipline in miniature, as ../virt/uart.c has it. Echo, map CR to
 * NL, and hand it to kbdq, which also sees the debug keys first.
 */
int
consuartputc(Queue *q, int c)
{
	USED(q);
	if(kbdq == nil)
		return 0;
	if(c == '\r')
		c = '\n';
	if(c == '\n')
		uartputc('\r');
	uartputc(c);
	return kbdputc(kbdq, c);
}

/*
 * The polled console's lock: re-entrant for the holding hart, bounded
 * so a stuck holder delays output rather than losing it, and off until
 * boardlockon()'s moment. See ../virt/uart.c.
 */
static ulong uartmutex;
static int uartowner = -1;
static int uartspl;
static int uartlocking;

void
uartlockon(void)
{
	uartlocking = 1;
}

int
uartlock(void)
{
	int i, s;

	if(!uartlocking)
		return 0;
	s = splhi();
	if(uartowner == m->machno){
		splx(s);
		return 0;
	}
	for(i = 0; i < 1000000; i++)
		if(_tas(&uartmutex) == 0){
			uartowner = m->machno;
			uartspl = s;
			return 1;
		}
	splx(s);
	return 0;
}

void
uartunlock(int held)
{
	int s;

	if(!held)
		return;
	s = uartspl;
	uartowner = -1;
	coherence();
	uartmutex = 0;
	splx(s);
}

void
uartputstr(char *s)
{
	int held;

	held = uartlock();
	while(*s){
		if(*s == '\n')
			uartputc('\r');
		uartputc(*s++);
	}
	uartunlock(held);
}

void
uartputx(u64int v)
{
	char buf[16];
	int i, held;

	for(i = 15; i >= 0; i--){
		buf[i] = "0123456789abcdef"[v & 0xF];
		v >>= 4;
	}
	held = uartlock();
	uartputc('0');
	uartputc('x');
	for(i = 0; i < 16; i++)
		uartputc(buf[i]);
	uartunlock(held);
}

void
uartputd(u64int v)
{
	char buf[20];
	int i, held;

	held = uartlock();
	if(v == 0)
		uartputc('0');
	else{
		i = 0;
		while(v > 0 && i < (int)sizeof(buf)){
			buf[i++] = '0' + (int)(v % 10);
			v /= 10;
		}
		while(--i >= 0)
			uartputc(buf[i]);
	}
	uartunlock(held);
}

void
uartputs(char *s, int n)
{
	int i, held;

	held = uartlock();
	for(i = 0; i < n; i++){
		if(s[i] == '\n')
			uartputc('\r');
		uartputc(s[i]);
	}
	uartunlock(held);
}

/*
 * The PhysUart: #t's view of the same part.
 */
extern PhysUart ns16550physuart;
static Uart consuart;

/*
 * Move the console to another UART of the same kind: what a board
 * does when its device tree's /chosen/stdout-path names a different
 * one from the board's default. Before interrupts, and before #t has
 * the console, so there is nothing to hand over but the address. The
 * firmware was using that UART, so its rate is left as it set it.
 */
void
uartconsole(uintptr base, int irq)
{
	int held;

	held = uartlock();
	consbase = base;
	consirq = irq;
	consuart.regs = (void*)base;
	uartunlock(held);
	uartinit();
}

static Uart consuart = {
	.regs	= (void*)(uintptr)UARTREGS,
	.name	= "uart0",
	.freq	= UARTCLK,
	.baud	= 115200,
	.bits	= 8,
	.stop	= 1,
	.parity	= 'n',
	.phys	= &ns16550physuart,
	.console= 1,
	.putc	= consuartputc,
};

PhysUart* physuart[] = {
	&ns16550physuart,
	nil,
};

static ulong nintr, nrx, ntx;

#define	UB(u)	((uintptr)(u)->regs)

static Uart*
pnp(void)
{
	return &consuart;
}

static void
interrupt(Ureg*, void *arg)
{
	Uart *uart;
	u32int lsr;

	uart = arg;
	nintr++;
	while((lsr = rd(UB(uart), Lsr)) & Dr){
		if(lsr & Oe)
			uart->oerr++;
		if(lsr & Pe)
			uart->perr++;
		if(lsr & Fe)
			uart->ferr++;
		nrx++;
		if(lsr & Bi){
			rd(UB(uart), Rbr);
			continue;	/* a break is not a byte */
		}
		uartrecv(uart, rd(UB(uart), Rbr) & 0xFF);
	}
	if(lsr & Thre)
		uartkick(uart);
}

static void
enable(Uart *uart, int ie)
{
	wr(UB(uart), Fcr, Fena | Frclr | Ftclr);
	wr(UB(uart), Mcr, Dtr | Rts | Out2);
	if(ie){
		intrenable(consirq, interrupt, uart, 0, uart->name);
		wr(UB(uart), Ier, Erda | Erls);
	}
}

static void
disable(Uart *uart)
{
	wr(UB(uart), Ier, 0);
}

static void
kick(Uart *uart)
{
	int n;
	u32int ier;

	if((rd(UB(uart), Lsr) & Thre) == 0){
		wr(UB(uart), Ier, rd(UB(uart), Ier) | Ethre);
		return;
	}
	/* an empty holding register takes one byte; its FIFO takes 16 */
	for(n = 0; n < 16; n++){
		if(uart->op >= uart->oe && uartstageoutput(uart) == 0)
			break;
		wr(UB(uart), Thr, *(uart->op++));
		ntx++;
	}
	ier = rd(UB(uart), Ier);
	if(uart->op < uart->oe)
		wr(UB(uart), Ier, ier | Ethre);
	else
		wr(UB(uart), Ier, ier & ~Ethre);
}

static void
lcr(Uart *uart, u32int set, u32int clr)
{
	wr(UB(uart), Lcr, (rd(UB(uart), Lcr) & ~clr) | set);
}

static void
dobreak(Uart *uart, int ms)
{
	lcr(uart, Brk, 0);
	microdelay(ms*1000);
	lcr(uart, 0, Brk);
}

static int
baud(Uart *uart, int n)
{
	if(uart->freq == 0 || n <= 0)
		return -1;
	setdivisor(UB(uart), uart->freq, n);
	uart->baud = n;
	return 0;
}

static int
bits(Uart *uart, int n)
{
	if(n < 5 || n > 8)
		return -1;
	lcr(uart, n - 5, 3);
	uart->bits = n;
	return 0;
}

static int
stop(Uart *uart, int n)
{
	switch(n){
	case 1:
		lcr(uart, 0, Stb);
		break;
	case 2:
		lcr(uart, Stb, 0);
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
		lcr(uart, 0, Pen);
		break;
	case 'e':
		lcr(uart, Pen|Eps, 0);
		break;
	case 'o':
		lcr(uart, Pen, Eps);
		break;
	default:
		return -1;
	}
	uart->parity = n;
	return 0;
}

static void
modemctl(Uart *uart, int on)
{
	uart->modem = on;
}

static void
rts(Uart *uart, int on)
{
	u32int mcr;

	mcr = rd(UB(uart), Mcr);
	wr(UB(uart), Mcr, on ? mcr | Rts : mcr & ~Rts);
}

static void
dtr(Uart *uart, int on)
{
	u32int mcr;

	mcr = rd(UB(uart), Mcr);
	wr(UB(uart), Mcr, on ? mcr | Dtr : mcr & ~Dtr);
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
		"dev(%d) type(%d) framing(%d) overruns(%d) parity(%d) "
		"berr(%d) serr(%d) freq(%lud)\n"
		"lsr(0x%ux) ier(0x%ux) lcr(0x%ux) mcr(0x%ux) msr(0x%ux) intrs(%lud) rx(%lud) tx(%lud)\n"
		"staged(%lud) read(%lud) qlen(%d) enabled(%d)\n",
		uart->baud, uart->hup_dcd, uart->dsr, uart->hup_dsr,
		uart->bits, uart->modem, uart->parity, uart->cts, uart->stop,
		uart->dev, uart->type, uart->ferr, uart->oerr, uart->perr,
		uart->berr, uart->serr, uart->freq,
		rd(UB(uart), Lsr), rd(UB(uart), Ier), rd(UB(uart), Lcr),
		rd(UB(uart), Mcr), rd(UB(uart), Msr), nintr, nrx, ntx,
		uart->nstaged, uart->nread, uart->iq != nil ? qlen(uart->iq) : -1, uart->enabled);
	n = readstr(offset, buf, n, p);
	free(p);
	return n;
}

static void
putc(Uart *uart, int c)
{
	long i;

	for(i = 0; (rd(UB(uart), Lsr) & Thre) == 0; i++)
		if(i >= Txspin)
			return;
	wr(UB(uart), Thr, c & 0xFF);
}

static int
getc(Uart *uart)
{
	if((rd(UB(uart), Lsr) & Dr) == 0)
		return -1;
	return rd(UB(uart), Rbr) & 0xFF;
}

PhysUart ns16550physuart = {
	.name		= "ns16550",
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
	.dtr		= dtr,
	.fifo		= donothing,
	.status		= status,
	.getc		= getc,
	.putc		= putc,
};
