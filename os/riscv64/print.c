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
 * print(), panic(), putstrn(), iprint(), kprint(), snprint(), sprint(),
 * _assert() and debugkey() were all defined here while there was no
 * console device. os/port/devcons.c owns them now, and routes them
 * through the console Queue so they interleave correctly on /dev/cons
 * instead of each racing straight to the UART.
 *
 * What remains is the seam libkern's fmt engine expects the KERNEL to
 * fill in, which devcons.c does not provide: the format lock and the
 * two verbs the kernel decides the meaning of.
 */

/*
 * Upstream sets a flag that makes print() bypass console queueing so a
 * panic message cannot be lost behind a lock. devcons.c reads that flag
 * (via its own machinery); this is the platform half, and there is
 * nothing to switch yet because the UART write below is unbuffered.
 */
void
setpanic(void)
{
}
