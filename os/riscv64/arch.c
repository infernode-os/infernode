/*
 * Interrupt level: sstatus.SIE, the one bit that decides whether this
 * hart takes S-mode interrupts at all.
 *
 * splhi and spllo return the previous level and splx restores exactly
 * that, which is the contract os/port relies on (see ../arm64/arch.c).
 * The value returned is the old sstatus with only SIE kept, so it is
 * nonzero exactly when interrupts were on.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

enum
{
	Sie	= 1<<1,
};

int
splhi(void)
{
	ulong s;

	__asm__ volatile("csrrci %0, sstatus, 2" : "=r"(s) :: "memory");
	return (int)(s & Sie);
}

int
spllo(void)
{
	ulong s;

	__asm__ volatile("csrrsi %0, sstatus, 2" : "=r"(s) :: "memory");
	return (int)(s & Sie);
}

void
splx(int s)
{
	if(s & Sie)
		__asm__ volatile("csrsi sstatus, 2" ::: "memory");
	else
		__asm__ volatile("csrci sstatus, 2" ::: "memory");
}

void
splxpc(int s)
{
	splx(s);
}

int
islo(void)
{
	ulong s;

	__asm__ volatile("csrr %0, sstatus" : "=r"(s));
	return (s & Sie) != 0;
}
