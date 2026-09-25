/*
 * Memory: physical addressing, no translation.
 *
 * An S-mode RISC-V kernel may run with satp in Bare mode, and this one
 * does. That is not the compromise it would be on arm64, where the MMU
 * has to be on before memory is cacheable and before load-exclusive
 * works (../arm64/main.c, startmmu): RISC-V's cacheability and
 * atomicity come from the platform's physical memory attributes, so
 * RAM is cacheable and LR/SC and AMOs work from the first instruction,
 * and device registers are uncached, with paging off.
 *
 * What paging would add is protection -- a read-only kernel text, a
 * guard below each kernel stack, a JIT mapping that is never writable
 * and executable at once. That is Sv39 work for later; the hooks below
 * are the interface it will fill in, and they report what is true now.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

void	boardmemory(uintptr*, uintptr*);	/* the board: RAM's base and size */

static uintptr ramtop;

void
mmuinit(void)
{
	uintptr base, size;

	boardmemory(&base, &size);
	ramtop = base + size;
}

void
mmuenable(void)
{
}

int
mmuon(void)
{
	return 0;
}

int
mmucaches(void)
{
	return 1;
}

uintptr
mmuramtop(void)
{
	return ramtop;
}

uintptr
mmuhightop(void)
{
	return ramtop;
}

uintptr
mmul1(void)
{
	return 0;
}

uintptr
mmumapped(void)
{
	return ramtop;
}

/* uncached memory for a device: physical attributes decide, not us */
void
mmunormalnc(uintptr base, usize len)
{
	USED(base);
	USED(len);
}
