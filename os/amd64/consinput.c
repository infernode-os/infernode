/*
 * os/amd64/consinput.c -- the console's receive side, polled.
 *
 * Until now the console was write-only: serwrite writes the 16550 and
 * nothing read it.  A shell needs the other direction, and this is it:
 * the receive byte, CR-to-NL and echo, then kbdputc's line discipline
 * and the queue /dev/cons reads through.
 *
 * Polled, deliberately, and not by choice of style: 9vm emulates the
 * 16550's LSR, IIR and RBR faithfully but does not raise IRQ4, so an
 * interrupt-driven receive would work under QEMU and never under the
 * loader the rest of this harness uses.  The clock is 100 Hz, so the
 * console is sampled every 10 ms; a keystroke cannot arrive faster than
 * that matters to a person at a terminal.
 *
 * Echo is here because nothing else does it.  devcons' echo() writes to
 * printq or screenputs, and this port sets neither (console output is
 * synchronous through serwrite), so without this the console is blind:
 * you type and see nothing, which reads exactly like input being
 * dropped.  Backspace erases as well as deleting, because sending a
 * bare BS only moves the cursor left.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "io.h"

#define COM1		0x3F8

/* the receiver holding register, if it has one for us */
int
uartgetc(void)
{
	if((inb(COM1+5) & 0x01) == 0)
		return -1;
	return inb(COM1);
}

/*
 * One received character: translate, echo, hand to the line discipline.
 *
 * kbdputc takes a Rune, so a UTF-8 sequence typed byte by byte is
 * assembled there.  This layer must not try to: it sees bytes.
 */
static int
consinputputc(Queue *q, int c)
{
	char b[1];

	if(kbdq == nil)
		return 0;		/* nothing typed before the console exists */
	if(c == '\r')
		c = '\n';
	if(c == '\b')
		conswrite("\b \b", 3);
	else if(c == 0x15)		/* ^U: kill the line */
		conswrite("^U\r\n", 4);
	else if(c == '\n')
		conswrite("\r\n", 2);
	else {
		b[0] = c;
		conswrite(b, 1);
	}
	return kbdputc(q, c);
}

static void
consinput(void *a)
{
	int c;

	USED(a);
	for(;;){
		while((c = uartgetc()) >= 0)
			consinputputc(kbdq, c);
		tsleep(&up->sleep, return0, nil, 10);
	}
}

/*
 * The poller, as a kernel process.  Called once the process table
 * exists; it runs as soon as the scheduler does, and tests that never
 * start the scheduler simply leave it queued.
 */
void
consinputinit(void)
{
	kproc("consinput", consinput, nil, 0);
}
