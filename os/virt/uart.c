/*
 * The serial console: policy over the PL011, polled.
 *
 * On virt the PL011 is the only UART and it is the console, which is
 * what it was on the board too until the radio took it (see
 * os/bcm/uart.c). QEMU's -serial goes to it, and with -nographic
 * that is the terminal QEMU was started from.
 *
 * Everything below consuartputc is os/bcm/uart.c's, unchanged, and
 * belongs to neither board: one core emits at a time, output is
 * synchronous because this is the path a panic takes, input is echoed
 * here because nothing above will. It is copied rather than shared
 * only until both boards have been seen to boot the same kernel; its
 * home is os/arm64.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "../port/uart.h"

extern PhysUart pl011physuart;

/* one UART, so /dev/eia0 is the console */
PhysUart* physuart[] = {
	&pl011physuart,
	nil,
};

enum
{
	/*
	 * The rate of the "apb-pclk" fixed clock in virt's device tree.
	 * QEMU's PL011 moves bytes however the divisors are set, so this
	 * decides nothing under emulation; it is what makes the divisors
	 * right if the model ever starts to care, and what the same part
	 * on a real board would need.
	 */
	Uartclk		= 24000000,
	Baud		= 115200,
};

#define UART(r)	(*(volatile u32int*)((uintptr)UART0REGS + (r)))

/*
 * Enable it before the first character, not on the assumption that
 * something already has. No firmware runs before this kernel on virt,
 * and QEMU's model follows the data sheet: a PL011 with UARTEN or TXE
 * clear accepts a write to the data register and sends nothing. The
 * symptom is a kernel that boots perfectly and says nothing at all.
 */
void
uartinit(void)
{
	u32int div64;

	UART(Cr) = 0;
	UART(Imsc) = 0;
	UART(Icr) = 0x7FF;
	div64 = (u32int)(((uvlong)Uartclk * 4 + Baud/2) / Baud);
	UART(Ibrd) = div64 >> 6;
	UART(Fbrd) = div64 & 63;
	UART(Lcrh) = Fen | Wlen8;	/* writing LCRH latches the divisors */
	UART(Cr) = Uarten | Txe | Rxe;
}

char*
uartdescribe(void)
{
	return "PL011 (UART0), polled; 24000000 Hz, 115200 baud";
}

void
uartputc(int c)
{
	while(UART(Fr) & Txff)
		;
	UART(Dr) = c & 0xFF;
}

/*
 * Non-blocking read of one character, or -1 if the receive FIFO is
 * empty. The polled path, for the probes that run before interrupts;
 * ordinary console input arrives on the PL011's interrupt and goes
 * through consuartputc below.
 */
int
uartgetc(void)
{
	u32int d;

	if(UART(Fr) & Rxfe)
		return -1;
	d = UART(Dr);
	if(d & Rxerrors)
		UART(Rsrecr) = 0;
	return d & 0xFF;
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
