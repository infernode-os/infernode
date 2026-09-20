/*
 * The serial console: policy over uartmini.c's polled mini-UART.
 *
 * This is the console of last resort: it works before the MMU, before
 * interrupts, and before any framebuffer exists, which makes it the only
 * way to see anything at all during early bring-up. On real hardware it
 * comes out of GPIO 14/15 and needs a USB-serial cable; under QEMU it is
 * serial1 -- the second -serial -- because the first is the PL011.
 *
 * It WAS the PL011, polled, from the first boot until the Bluetooth
 * work (docs/BLUETOOTH.md): on a Pi 3 that UART is wired to the radio,
 * so the console moved to the mini-UART, which is where Plan 9 and
 * Linux put it for the same reason. The header pins did not change --
 * 14/15 carry either UART, on ALT0 or ALT5 -- and serialboot, which
 * runs before this kernel and still speaks PL011 on them, did not
 * change either. The PL011 register code became uartpl011.c, a
 * PhysUart under #t as /dev/eia0.
 *
 * What this file keeps is the console's policy, which is the same on
 * either UART: output is synchronous and polled, because this is the
 * path a panic takes and a panic that queues its output can lose it;
 * one core emits at a time; and input is echoed here, at the driver,
 * because nothing above it will (see consuartputc).
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "../port/uart.h"

/*
 * The board's UARTs, in the order that names them under #t:
 * eia0 is the PL011 (the radio's), eia1 the mini-UART (the console's).
 * docs/BLUETOOTH.md fixes those names; bt9p opens /dev/eia0.
 */
extern PhysUart pl011physuart;
extern PhysUart miniphysuart;

PhysUart* physuart[] = {
	&pl011physuart,
	&miniphysuart,
	nil,
};

static ulong corehz;	/* what the mini-UART's divisor was computed from */

/*
 * Bring the console up. uartmini.c asks the firmware for the core
 * clock before it enables anything, since a divisor from the wrong
 * clock makes every later character unreadable; the rate it used is
 * announced by kmain's banner so that a garbled console at least has
 * a number to argue with (uartdescribe).
 *
 * The rate is NOT changed from 115200 here, and the reasoning that
 * used to sit at this spot about 921600 still stands: bring the
 * console up at the rate the cable expects, print the divisors, and
 * only then switch -- so a failure is visible and the machine is
 * still talking. Nobody has needed the switch since the network
 * console arrived. serialboot is separate and stays at 115200.
 */
void
uartinit(void)
{
	corehz = miniconsinit();
}

/*
 * For the banner, before print() works: no snprint, no allocation,
 * so the decimal is built in place. Under QEMU the firmware model
 * reports 350000000; a board with enable_uart=1 reports 250000000, and
 * one without it reports whatever the firmware scaled to, which is
 * the number to look at when the console reads as noise.
 */
char*
uartdescribe(void)
{
	static char buf[80];
	char num[24];
	char *p, *s;
	int i;
	ulong v;

	s = "mini-UART (UART1), polled; core clock ";
	p = buf;
	while(*s)
		*p++ = *s++;
	v = corehz;
	i = 0;
	do{
		num[i++] = '0' + v % 10;
		v /= 10;
	}while(v > 0);
	while(--i >= 0)
		*p++ = num[i];
	s = " Hz, 115200 baud";
	while(*s)
		*p++ = *s++;
	*p = 0;
	return buf;
}

void
uartputc(int c)
{
	miniputc(c);
}

/*
 * Non-blocking read of one character, or -1 if the receive FIFO is
 * empty. The polled path: probeuartin and the recovery console use
 * it, before or instead of interrupts. Ordinary console input does
 * not come this way any more -- it arrives on the mini-UART's receive
 * interrupt and goes through consuartputc below.
 */
int
uartgetc(void)
{
	return minigetc();
}

/*
 * Console input at interrupt time: what #t's console Uart does with
 * each received byte (uartrecv -> putc). This replaced a kproc that
 * polled uartgetc() every 10ms and, the board notes recorded, lost
 * everything past the 16-byte FIFO of any burst a script sent.
 *
 * Enter sends CR, not NL -- every terminal emulator does, and so does
 * anything driving this line from a script. consread()'s cooked-mode
 * line discipline ends a line on NL (or ^D) and nothing else, so an
 * untranslated CR would be appended to kbd.line as an ordinary
 * character and the line never terminated. This is what ICRNL does on
 * any other system, and the driver that owns the line is the place.
 *
 * Echo here too, because nothing else will. echo() in devcons writes
 * to printq or to a bitmapped display; printq is deliberately never
 * set in this tree (console output stays synchronous, above) and this
 * board has no screen, so without this the console is blind -- you
 * type and see nothing, which reads exactly like input being dropped.
 * Not via screenputs: putstrn0 already sends kernel output down the
 * same wire through serwrite, so borrowing the screen hook would
 * double every line the kernel prints.
 *
 * kbdputc does the line discipline -- backspace, kill, the debug keys
 * -- and hands complete lines to kbdq, which is what /dev/cons reads.
 * When kbdq is full it drops the byte and says so, rate-limited; the
 * stall-and-wait the old kproc did is gone with it, and so is the
 * failure mode where a dead reader made the console deaf to the debug
 * keys that could have said what died.
 */
int
consuartputc(Queue *q, int c)
{
	USED(q);
	/*
	 * Before consinit() there is no kbdq to produce into. A card-booted
	 * kernel never receives this early, but a kernel loaded over the
	 * wire inherits the loader's PL011 with the tail of the handshake
	 * in its FIFO, and the first spllo() delivered it straight into
	 * qproduce(nil) -- ilock on address 0, and the loader's whole
	 * point, a bad kernel without a card pull, was lost to it (#639).
	 * Nothing typed before the console exists is worth keeping.
	 */
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
 * One writer at a time, whole string. Four cores printing through
 * this interleaved CHARACTER BY CHARACTER: "cpu1: up" and "cpu2: up"
 * came out as "cpuccp1: uppuu2", which is comedy until a panic
 * message does it, and the first SMP panic did exactly that -- the
 * one line that would have named the bug was shredded across three
 * cores' output. A plain spin lock is enough: emission is short and
 * bounded. _tas directly rather than lock() so a panic INSIDE the lock
 * machinery can still print: after a bounded spin, print anyway --
 * garbled beats silent.
 *
 * uartowner is the core holding uartmutex, or -1, and the lock is
 * held at splhi. Together they do three jobs.
 *
 * First, a writer that gave up waiting must not release the lock on
 * its way out. The first version did: "spin, print, store 0" with no
 * memory of whether the spin had succeeded, so a core that had timed
 * out and printed over the holder then also FREED THE HOLDER'S LOCK,
 * and a third core walked straight in. Only the acquirer stores the 0.
 *
 * Second, the same core re-enters this file while holding the lock:
 * dumpureg holds it across a whole report and calls uartputstr for
 * each line, and a fault taken INSIDE an emission -- the panic path --
 * prints from the same core again. Before, that inner print spun out
 * the whole bound -- a million exclusive loads at splhi -- and then
 * printed anyway. Now it recognises its own core as the holder and
 * writes through at once, leaving the release to the outer call.
 *
 * Third, and this is why splhi: the owner is named by CORE, but the
 * holder that matters is a PROCESS. uartputs() is the console write,
 * called from putstrn0 in process context at spllo, and hzclock now
 * preempts on every core. Held at spllo, a process could be
 * descheduled mid-line with the lock, be picked up by any idle core
 * (runproc's second pass ignores affinity) and resume writing there;
 * back on the core it left, uartowner still named that core, so the
 * next print there took the "my own core holds it" exit and wrote
 * straight through -- two cores emitting at once, which is the one
 * thing the lock exists to prevent -- while an interrupt-time print on
 * the new core saw a foreign owner and spun the whole bound. Raising
 * splhi before the spin and holding it until the release means the
 * holder cannot be preempted, so it cannot migrate, so the core IS the
 * holder for as long as the lock is held; the same discipline as
 * ilock. The cost is interrupts masked on one core for one emission:
 * conswrite chunks at 256 bytes, about 22ms at 115200 baud on the
 * board, and a pending tick is delayed, not lost. The nested case
 * above is unchanged by it -- with interrupts masked, the only way
 * back into this file on the holding core is a synchronous exception
 * or a direct call, and both are the same core.
 */
static ulong uartmutex;
static int uartowner = -1;
static int uartspl;		/* the acquirer's level, for uartunlock */

/*
 * ...and NOT ONE writer before the MMU is on. _tas is a load/store
 * exclusive, and exclusives with the MMU off FAULT on real silicon --
 * the same lesson the mailbox lock taught (see mboxlockon), relearned
 * here when the first SMP kernel on hardware printed its probe
 * letters and died at the banner: QEMU permits MMU-off exclusives,
 * so 147 green checks never noticed. Locking starts when kmain says
 * so, and before that there is one thread of control anyway.
 */
static int uartlocking;

void
uartlockon(void)
{
	uartlocking = 1;
}

/*
 * Take the console for one emission. Returns whether THIS call took the
 * lock, and that value -- not a guess -- is what uartunlock() wants
 * back: 0 means locking is off, or this core already holds it from an
 * outer call, or the bounded spin gave up and the text is going out
 * over somebody else's. In none of those cases is the lock ours to free.
 *
 * Exported so a multi-line report (dumpureg, intrdump) can hold the
 * console across all of its lines rather than only within each one;
 * the nested-owner rule above is what makes that safe for the
 * uartputstr() calls inside it.
 */
int
uartlock(void)
{
	int i, s;

	if(!uartlocking)
		return 0;
	/*
	 * splhi before the test-and-set, not after: a tick between a
	 * successful _tas and a later splhi would leave a Ready process
	 * holding the console lock with interrupts on -- the migration
	 * case described above, in a narrower window.
	 */
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
	/*
	 * Gave up: the text goes out over the holder's, at the caller's
	 * level. Nothing was taken, so nothing is held and nothing is
	 * restored later; put the level back here.
	 */
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

/*
 * The numbers are emitted under the lock too, as one piece. They used
 * to go out by bare uartputc() after a locked "0x", so a register dump
 * from one core could carry another core's digits in the middle of a
 * value -- and a value with foreign digits in it is not a wrong value
 * that can be spotted, it is a plausible one.
 */
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
	int i, held;

	held = uartlock();
	for(i = 0; i < n; i++){
		if(s[i] == '\n')
			uartputc('\r');
		uartputc(s[i]);
	}
	uartunlock(held);
}
