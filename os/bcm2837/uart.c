/*
 * PL011 UART0 on BCM2837, polled output only.
 *
 * This is the console of last resort: it works before the MMU, before
 * interrupts, and before any framebuffer exists, which makes it the only
 * way to see anything at all during early bring-up.  On real hardware it
 * comes out of GPIO 14/15 and needs a USB-serial cable; under QEMU it is
 * serial0, so plain -serial stdio picks it up.
 */

#include "dat.h"
#include "io.h"

#define UART(r)	(*(volatile u32int*)(UART0REGS + (r)))
#define GPIO(r)	(*(volatile u32int*)(GPIOREGS + (r)))

static void
delay(int n)
{
	while(n-- > 0)
		__asm__ volatile("nop");
}

void
uartinit(void)
{
	u32int r;

	UART(Cr) = 0;			/* disable while reconfiguring */

	/* GPIO 14 and 15 to ALT0 == TXD0/RXD0 */
	r = GPIO(Gpfsel1);
	r &= ~((7<<12) | (7<<15));
	r |= (4<<12) | (4<<15);
	GPIO(Gpfsel1) = r;

	/*
	 * Detach the pull-up/pull-down on 14/15.  The 150-cycle waits are
	 * required by the BCM peripheral spec: the pull state is clocked
	 * in, not written directly.
	 */
	GPIO(Gppud) = 0;
	delay(150);
	GPIO(Gppudclk0) = (1<<14) | (1<<15);
	delay(150);
	GPIO(Gppudclk0) = 0;

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
uartputs(char *s)
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
	uartputs("0x");
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
