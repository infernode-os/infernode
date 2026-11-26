/*
 * The seam libkern's formatting engine expects the machine to fill in.
 *
 * dofmt is shared code and cannot know how this kernel serialises or
 * what the kernel-specific verbs mean, so it calls out here: the format
 * lock, and %e/%f/%g and %r.  The native kernel has never formatted
 * floating point, so _efgfmt reports failure rather than pretending.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

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

int
_efgfmt(Fmt *f)
{
	USED(f);
	return -1;
}

/*
 * %r -- the process's error string.  Formatting it through the same
 * engine would recurse, so return failure until a caller needs it.
 */
int
errfmt(Fmt *f)
{
	USED(f);
	return -1;
}
