/*
 * os/amd64/fpwork.c -- a second floating point user, to test the
 * scheduler's FP save.
 *
 * Built with SSE (VFLAGS, like libinterp), it holds a double in an XMM
 * register for a whole second of ticks while the Dis VM does real
 * arithmetic on the same core; the clock preempts one with the other.
 * If procsave()/procrestore() did not FXSAVE and FXRSTOR the XMM file,
 * the sum would be something else, and the boot says so instead of
 * passing.
 *
 * The invariant is exact: summing 1.0 n times must equal (double)n for
 * every n below 2^53, whatever n the second produced.  A loop short
 * enough to finish between two ticks would prove nothing, so it is
 * bounded by the clock rather than by a count.
 *
 * This process also halts the machine.  The Limbo program prints its
 * verdict and then sleeps, so that the check that ends the boot is the
 * one that measured the scheduler -- and so that it takes the same
 * guest time under 9vm and under QEMU's TCG.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"

/*
 * The clock is written by the timer interrupt, so its reads are
 * volatile.  Without that the optimiser hoists the load out of the loop,
 * sees ticks < ticks+100 as always true, and deletes the loop and the
 * check with it: an infinite loop with no visible side effect may be
 * assumed to terminate.  That is not a hypothetical -- the first version
 * of this file reported "ok (0 additions)".
 */
static ulong
nowticks(void)
{
	return *(volatile ulong*)&m->ticks;
}

void
fpwork(void *a)
{
	double sum;
	ulong n, end;

	USED(a);
	sum = 0.0;
	n = 0;
	end = nowticks() + 100;		/* one second at 100 Hz */
	while(nowticks() < end){
		sum += 1.0;
		n++;
	}
	if(sum != (double)n){
		print("vmtest failed: fp worker sum %g after %lud additions\n",
			sum, n);
		conshalt();
	}
	print("vmtest: fp worker ok (%lud additions across 100 ticks)\n", n);
	conshalt();
}
