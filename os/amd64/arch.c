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

/*
 * x86 has no caches for software to clean (the caches are coherent) and
 * no store buffer for code to worry about in this direction; the
 * compiler barrier is what stops the stores moving across the publish.
 */
void
coherence(void)
{
	__asm__ volatile("mfence" ::: "memory");
}

/*
 * The scheduler's idle wait: the caller is at splhi, so interrupts are
 * opened across the hlt (or the wait would never end) and shut again
 * before it returns.
 */
void
idlehands(void)
{
	__asm__ volatile("sti; hlt; cli" ::: "memory");
}

/* One core: there is nobody to wake. */
void
idlewake(void)
{
}

/* The panic and clock-check hooks os/port calls; nothing to do yet. */
void
setpanic(void)
{
}

void
clockcheck(void)
{
}
