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
#include "board.h"

enum
{
	Txspin = 10*1000*1000,	/* generous; only a wedged line reaches it */
};

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

	/*
	 * 115200 baud from the 48MHz UART reference clock.
 *
 * REVERTED FROM 921600, AND HERE IS WHAT HAPPENED, because the next
 * attempt should not start from scratch.
 *
 * IBRD 3 / FBRD 16 is the correct divisor pair for 921600 -- 923077,
 * 0.16% error -- and the write order here is right: the PL011 latches
 * the divisors when LCRH is written, and LCRH is written after them.
 * The adapter is a CH340 and macOS accepted 921600 on it. It still
 * came back as garbage, with MORE bytes arriving at 921600 than at any
 * other rate, which says the board was transmitting somewhere near but
 * not at that rate.
 *
 * The suspect is FBRD not taking effect, which would leave IBRD 3
 * alone: 48e6/(16*3) is exactly 1000000, an 8.5% mismatch against
 * 921600 -- garbage, and unreachable besides, because macOS refuses to
 * set 1000000 on this adapter. That fits every symptom including
 * being locked out of the board entirely.
 *
 * WHAT TO DO DIFFERENTLY. Do not change the rate the early console
 * comes up at. Bring the console up at 115200, PRINT the divisors and
 * the intended rate, and only then switch -- so a failure is visible
 * and the machine is still talking. Better still, prove the divisors
 * by reading IBRD and FBRD back before relying on them.
	 *
	 * PL011 divisor: 48e6/(16*921600) = 3.2552, so IBRD 3 and FBRD
	 * round(0.2552*64) = 16. That gives 48e6/(16*3.25) = 923077, an
	 * error of 0.16% -- an order inside the 2-3% a UART pair
	 * tolerates. (115200 was IBRD 26, FBRD 3, for 115177.)
	 *
	 * WHY IT IS WORTH CHANGING. Every kernel iteration on this board
	 * pushes the whole image down this wire, and the image is now
	 * 1.68MB: measured, 159.5 seconds at 115200. At this rate it is
	 * about eighteen. That is the difference between a three-minute
	 * edit-test cycle and a thirty-second one, and this port does a
	 * lot of them.
	 *
	 * The reference clock is 48MHz because UART0 is fed by
	 * init_uart_clock, not by core_freq -- the clock that moves with
	 * the mini-UART is not this one. Empirically confirmed by 26/3
	 * having produced working 115200 all along.
	 *
	 * SERIALBOOT IS DELIBERATELY NOT CHANGED WITH THIS. It lives on
	 * the card and the only way to replace it is a copy from a
	 * running kernel, so a loader that talks at a rate the host does
	 * not expect is unreachable and means taking the card out. The
	 * kernel is the recoverable half: if this is wrong, the console
	 * garbles and the loader -- still at 115200 -- takes a corrected
	 * kernel. Change that one only once this one is proven.
	 */
	UART(Ibrd) = 26;
	UART(Fbrd) = 3;

	UART(Lcrh) = Fen | Wlen8;
	UART(Imsc) = 0;			/* polled; no interrupts yet */
	UART(Cr) = Uarten | Txe | Rxe;
}

void
uartputc(int c)
{
	long i;

	/*
	 * Bounded: a transmitter that never drains would otherwise hang
	 * every print(), including the one trying to report the fault.
	 * Dropping the character is the right failure -- the console is
	 * a diagnostic, not a contract.
	 */
	for(i = 0; UART(Fr) & Txff; i++)
		if(i >= Txspin)
			return;
	UART(Dr) = c;
}

/*
 * Non-blocking read of one character, or -1 if the receive FIFO is
 * empty.
 *
 * The console has been write-only until now, which was enough to watch
 * the kernel boot and nothing more: a shell that cannot be typed at is
 * a log, not a session.
 */
int
uartgetc(void)
{
	u32int d;

	if(UART(Fr) & Rxfe)
		return -1;

	/*
	 * The data register carries the receive ERROR flags in bits 8-11
	 * alongside the byte: framing, parity, break and overrun. They
	 * latch, and they are cleared by writing the receive-status
	 * register -- not by reading the data. Ignoring them entirely, as
	 * this did, means an overrun during boot leaves a flag set for
	 * ever and the byte itself is returned with high bits that are
	 * not data.
	 *
	 * Under emulation nothing ever overruns, so this could not have
	 * shown up before there was a real line with real timing on it.
	 */
	d = UART(Dr);
	if(d & Rxerrors)
		UART(Rsrecr) = 0;
	return d & 0xFF;
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
