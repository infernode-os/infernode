/*
 * PL011 UART0 on the QEMU virt machine, polled output only.
 *
 * Structurally the same driver as os/bcm2837/uart.c -- it is the same
 * PL011 -- with two differences worth naming rather than leaving to be
 * spotted in a diff:
 *
 *   There is no pin mux. On a Pi the PL011 only reaches the outside
 *   world once GPIO 14/15 are switched to ALT0; here it is wired to
 *   serial0 by the machine model and needs nothing.
 *
 *   The reference clock is 24MHz rather than 48MHz, so the baud rate
 *   divisors differ. QEMU's PL011 model ignores them entirely -- it is
 *   a character device, not a shift register -- but writing the right
 *   ones costs nothing and means the numbers here are not quietly wrong
 *   if this driver is ever pointed at a real PL011.
 *
 * The UART must be ENABLED before a write to the data register produces
 * anything. That is not a formality on QEMU: bring-up here spent a while
 * on a kernel that ran perfectly and printed nothing, because writing DR
 * with UARTEN clear is silently dropped.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define UART(r)	(*(volatile u32int*)((uintptr)UART0REGS + (r)))

void
uartinit(void)
{
	UART(Cr) = 0;			/* disable while reconfiguring */
	UART(Icr) = 0x7FF;		/* clear all pending interrupts */

	/* 115200 baud from the 24MHz reference clock: 24e6/(16*115200) = 13.02 */
	UART(Ibrd) = 13;
	UART(Fbrd) = 1;

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
 * The UART console write devcons.c calls -- a counted write, not a C
 * string. Unbuffered and synchronous on purpose: this is the path a
 * panic takes, and a panic that queues its output can lose it.
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
