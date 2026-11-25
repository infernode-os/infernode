/*
 * os/amd64/arch.c -- interrupt priority levels.
 *
 * Plan 9 and Inferno kernels talk about "spl" -- set priority level --
 * from the PDP-11.  x86 has one mask bit that matters here, RFLAGS.IF,
 * so "high" means interrupts off and "low" means on, and the whole
 * RFLAGS word is the saved state.
 *
 * The contract os/port relies on is that splhi and spllo RETURN the
 * previous state so splx can restore exactly what it found; code that
 * unconditionally enables interrupts on the way out silently unmasks a
 * caller that had masked them.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

enum
{
	Iflag	= 1<<9,		/* RFLAGS.IF */
};

static ulong
rdflags(void)
{
	ulong f;

	__asm__ volatile("pushfq; popq %0" : "=r"(f));
	return f;
}

int
splhi(void)
{
	ulong f;

	f = rdflags();
	__asm__ volatile("cli" ::: "memory");
	return (int)f;
}

int
spllo(void)
{
	ulong f;

	f = rdflags();
	__asm__ volatile("sti" ::: "memory");
	return (int)f;
}

void
splx(int s)
{
	if(s & Iflag)
		__asm__ volatile("sti" ::: "memory");
	else
		__asm__ volatile("cli" ::: "memory");
}

int
islo(void)
{
	return (rdflags() & Iflag) != 0;
}
