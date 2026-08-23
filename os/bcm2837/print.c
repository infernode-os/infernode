/*
 * The seam libkern's formatting engine expects the kernel to fill in.
 *
 * Mirrors upstream's os/port/print.c.  dofmt is shared code and cannot
 * know how this kernel serialises or how it renders the %r and %e/%f/%g
 * verbs, so it calls out to these four.
 *
 * Note that upstream's kernel also stubs _efgfmt to -1: the native
 * kernel has never formatted floating point.  That is why libkern's
 * charstod.c and pow10.c are not imported here -- they are the only
 * files that need hardware FP, and nothing would call them.
 */

#include "u.h"
#include "../port/lib.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

/*
 * A spinlock built straight on _tas.
 *
 * Upstream uses lock()/unlock() from os/port/taslock.c, which is not
 * imported yet because it depends on the whole Proc and scheduler layer
 * (up, conf.nmach, sched(), anyhigher()). This is the same exclusion
 * with none of those dependencies, and it should be replaced by the real
 * lock() the moment taslock.c lands rather than kept as a second
 * locking primitive.
 */
static ulong fmtl;

void
_fmtlock(void)
{
	while(_tas(&fmtl) != 0)
		;
}

void
_fmtunlock(void)
{
	coherence();
	fmtl = 0;
}

/*
 * %e, %f and %g. Returning -1 makes dofmt emit its error marker rather
 * than pretending to format a value it cannot.
 */
int
_efgfmt(Fmt *f)
{
	USED(f);
	return -1;
}

/*
 * %r -- the system error string. There is no error string mechanism yet
 * (that arrives with os/port's error.h and up->env), so report failure
 * rather than print something misleading.
 */
int
errfmt(Fmt *f)
{
	USED(f);
	return -1;
}

/*
 * print() and panic().
 *
 * os/port calls these constantly, and both are variadic, so they can
 * only exist once the fmt engine does. Output goes straight to the
 * PL011 rather than through a console queue: there is no /dev/cons yet,
 * and more importantly a panic must be able to reach the wire when the
 * rest of the kernel is already broken.
 *
 * The buffer is static and the printing is not re-entrant. That is the
 * usual bargain for kernel print: a fixed buffer that cannot itself
 * fail to allocate is worth more than reentrancy in the one code path
 * whose job is to report that something has gone wrong.
 */
static char printbuf[1024];

int
print(char *fmt, ...)
{
	va_list arg;
	int n;

	_fmtlock();
	va_start(arg, fmt);
	n = vsnprint(printbuf, sizeof printbuf, fmt, arg);
	va_end(arg);
	uartputstr(printbuf);
	_fmtunlock();

	return n;
}

void
panic(char *fmt, ...)
{
	va_list arg;

	/*
	 * Mask interrupts first. A timer tick arriving mid-panic would
	 * re-enter the kernel through a path that is, by definition, no
	 * longer trustworthy.
	 */
	splhi();

	uartputstr("\npanic: ");

	va_start(arg, fmt);
	vsnprint(printbuf, sizeof printbuf, fmt, arg);
	va_end(arg);
	uartputstr(printbuf);

	uartputstr("\nhalted.\n");

	for(;;)
		__asm__ volatile("wfe");
}

/*
 * Hooks os/port/xalloc.c calls that belong to subsystems not yet
 * imported: ixsummary is the interrupt-time allocation report, and
 * debugkey registers a console debug key. Both are reporting aids, so
 * stubbing them changes no behaviour -- but they are declared here
 * rather than deleted from xalloc.c so that file stays diff-able
 * against upstream.
 */
void
ixsummary(void)
{
	print("xalloc: ialloc %lud\n", conf.ialloc);
}

void
debugkey(Rune c, char *name, void (*f)(void), int t)
{
	USED(c); USED(name); USED(f); USED(t);
}

/*
 * Raw console write. os/port uses this to get bytes out without going
 * through the fmt engine -- notably from the pool allocator's corruption
 * reporter, which must be able to speak when the heap is already
 * suspect.
 */
void
putstrn(char *s, int n)
{
	int i;

	for(i = 0; i < n; i++){
		if(s[i] == '\n')
			uartputc('\r');
		uartputc(s[i]);
	}
}

/*
 * Upstream sets a flag that makes print() bypass any console queueing so
 * a panic message cannot be lost behind a lock. Output here already goes
 * straight to the PL011, so there is nothing to switch -- but the
 * function must exist, and when a console driver lands it becomes the
 * place that switch happens.
 */
void
setpanic(void)
{
}

/*
 * return0, tsleep and exhausted used to be stubbed here. os/port/proc.c
 * now provides the real ones -- tsleep genuinely sleeps, and exhausted
 * kills the offending process instead of just reporting -- so the stubs
 * are gone rather than shadowing them.
 */
