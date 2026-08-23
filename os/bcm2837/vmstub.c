/*
 * Placeholders for the three libinterp symbols os/port/alloc.c needs.
 *
 * The pool allocator is not independent of the Dis VM: it stamps the GC
 * colour into every heap block it hands out, asks the running Prog
 * whether it is memory-restricted before growing a pool, and keeps the
 * GC's sweep pointer consistent when it coalesces free blocks. Those are
 * real couplings, not incidental ones -- which is why the allocator and
 * the VM are usually brought up together.
 *
 * Linking libinterp is Layer 5, and everything between here and there
 * (proc.c, chan.c, sysfile.c, qio.c, dis.c) has to exist first. Rather
 * than defer the allocator until then, these three definitions let it
 * run and be tested now.
 *
 * DELETE THIS FILE when libinterp is linked. Each definition below is
 * the real symbol's declared type, so the linker will object loudly to a
 * duplicate rather than silently preferring one.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "interp.h"

/*
 * The GC's current mutator colour, from libinterp/gc.c. Heap blocks are
 * stamped with it on allocation so the collector can tell what it has
 * already seen. With no collector running, any consistent value does;
 * zero matches the initial state libinterp starts in.
 */
int mutator;

/*
 * The GC's sweep pointer, from libinterp/gc.c. poolfree() fixes it up
 * when it coalesces a free block that the sweep happens to be sitting
 * on, so it must exist even when nothing sweeps.
 */
Bhdr *ptr;

/*
 * The currently running Dis program, from libinterp. poolalloc() asks it
 * whether it carries Prestricted before letting a pool grow past its
 * reserved size. Returning nil means "no Dis program is running", which
 * is exactly true here, and makes that check fall through to the
 * unrestricted path.
 */
Prog*
currun(void)
{
	return nil;
}
