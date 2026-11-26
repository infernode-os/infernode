/*
 * os/amd64/nocomp.c -- the Dis-to-native code generator, absent.
 *
 * The interpreter runs every module; nothing here turns Dis into
 * x86-64.  That is a deliberate stage boundary rather than an omission:
 * comp-amd64.c places generated code with mmap(), and this kernel has
 * no mmap and no per-process address spaces yet.  The JIT arrives with
 * the code window it needs.
 *
 * What remains here is the small surface libinterp links against
 * whether or not a generator exists.  compile() is called only when
 * cflag is set or a module is marked MUSTCOMPILE (libinterp/load.c),
 * and returning 0 means "this kernel cannot compile it", which is the
 * truth; comvec is the dispatch table generated code jumps through and
 * is never read with no compiled modules; freetypejit() releases a
 * type's generated glue and freejitcode() a module's code, both of
 * which are unreachable when nothing was generated.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "isa.h"
#include "interp.h"
#include "kernel.h"

void	(*comvec)(void);

int
compile(Module *m, int size, Modlink *ml)
{
	USED(m);
	USED(size);
	USED(ml);
	kwerrstr("no Dis code generator in this kernel; interpreted only");
	return 0;
}

void
compileabort(void)
{
}

void
freejitcode(void *p, ulong size)
{
	USED(p);
	USED(size);
}

void
freetypejit(Type *t)
{
	USED(t);
}
