/*
 * Interrupt priority level, AArch64.
 *
 * Plan 9 and Inferno kernels talk about "spl" -- set priority level --
 * inherited from the PDP-11. On this architecture there is no priority
 * ladder to climb, only the DAIF mask bits, so "high" means IRQs masked
 * and "low" means IRQs enabled.
 *
 * The contract os/port relies on is that splhi and spllo RETURN THE
 * PREVIOUS state, so a caller can restore exactly what it found rather
 * than assuming. Code that masks interrupts and then unconditionally
 * enables them on the way out will silently enable interrupts inside a
 * caller that had deliberately masked them -- a bug that shows up as
 * rare corruption in an unrelated subsystem.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

/*
 * DAIF bit 7 is I, the IRQ mask. The whole DAIF word is returned as the
 * saved state rather than just that bit, so splx restores F (FIQ) and
 * the debug/abort masks too if anything ever touches them.
 */
enum
{
	Daifi	= 1<<7,
};

static u64int
rddaif(void)
{
	u64int v;

	__asm__ volatile("mrs %0, daif" : "=r"(v));
	return v;
}

ulong
splhi(void)
{
	u64int d;

	d = rddaif();
	__asm__ volatile("msr daifset, #2" ::: "memory");
	__asm__ volatile("isb");
	return (ulong)d;
}

ulong
spllo(void)
{
	u64int d;

	d = rddaif();
	__asm__ volatile("msr daifclr, #2" ::: "memory");
	__asm__ volatile("isb");
	return (ulong)d;
}

void
splx(ulong s)
{
	__asm__ volatile("msr daif, %0" :: "r"((u64int)s) : "memory");
	__asm__ volatile("isb");
}

/*
 * splxpc exists in os/port as a variant that records where the level was
 * restored from, for lock debugging. Nothing here needs that yet, so it
 * is the same operation under the name os/port expects.
 */
void
splxpc(ulong s)
{
	splx(s);
}

int
islo(void)
{
	return (rddaif() & Daifi) == 0;
}
