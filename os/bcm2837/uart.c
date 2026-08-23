/*
 * PL011 UART0 on BCM2837, polled output only.
 *
 * This is the console of last resort: it works before the MMU, before
 * interrupts, and before any framebuffer exists, which makes it the only
 * way to see anything at all during early bring-up.  On real hardware it
 * comes out of GPIO 14/15 and needs a USB-serial cable; under QEMU it is
 * serial0, so plain -serial stdio picks it up.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

#define UART(r)	(*(volatile u32int*)((uintptr)UART0REGS + (r)))

void
uartinit(void)
{
	UART(Cr) = 0;			/* disable while reconfiguring */

	/*
	 * GPIO 14 and 15 carry TXD0/RXD0 on alternate function 0, with no
	 * pull needed since the line is actively driven at both ends.
	 * Going through the GPIO driver rather than poking GPFSEL here
	 * keeps one owner of the pin mux -- and means every boot exercises
	 * that driver before anything else depends on it.
	 */
	gpiofunc(14, Gpioalt0);
	gpiofunc(15, Gpioalt0);
	gpiopull(14, Pullnone);
	gpiopull(15, Pullnone);

	UART(Icr) = 0x7FF;		/* clear all pending interrupts */

	/* 115200 baud from the 48MHz UART reference clock */
	UART(Ibrd) = 26;
	UART(Fbrd) = 3;

	UART(Lcrh) = Fen | Wlen8;
	UART(Imsc) = 0;			/* polled; no interrupts yet */
	UART(Cr) = Uarten | Txe | Rxe;
}

void
uartputc(int c)
{
	while(UART(Fr) & Txff)
		;
	UART(Dr) = c;
}

void
uartputstr(char *s)
{
	while(*s){
		if(*s == '\n')
			uartputc('\r');
		uartputc(*s++);
	}
}

void
uartputx(u64int v)
{
	char buf[16];
	int i;

	for(i = 15; i >= 0; i--){
		buf[i] = "0123456789abcdef"[v & 0xF];
		v >>= 4;
	}
	uartputstr("0x");
	for(i = 0; i < 16; i++)
		uartputc(buf[i]);
}

void
uartputd(u64int v)
{
	char buf[20];
	int i;

	if(v == 0){
		uartputc('0');
		return;
	}
	i = 0;
	while(v > 0 && i < (int)sizeof(buf)){
		buf[i++] = '0' + (int)(v % 10);
		v /= 10;
	}
	while(--i >= 0)
		uartputc(buf[i]);
}

/*
 * The UART console write devcons.c calls.
 *
 * portfns.h declares this as uartputs(char*, int) -- a counted write to
 * the serial console, not a C string. It is the reason this port's own
 * convenience helper is named uartputstr: the name belongs to os/port's
 * interface, not to a local shortcut.
 *
 * Unbuffered and synchronous on purpose. This is the path a panic takes,
 * and a panic that queues its output can lose it.
 */
void
uartputs(char *s, int n)
{
	int i;

	for(i = 0; i < n; i++){
		if(s[i] == '\n')
			uartputc('\r');
		uartputc(s[i]);
	}
}
