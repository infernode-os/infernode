/*
 * os/amd64/port.c -- the globals os/port expects a platform to define.
 *
 * One processor, so one Mach, and `m` points at it.  The values here
 * are the ones a single-CPU kernel with a flat identity map can state
 * now; allocation, the clock and the process table fill in the rest as
 * those files arrive.  conf.base0/npage0 describe the free bank the
 * caller measured: above the kernel image and below any reserved
 * region, so xalloc never hands out the image itself.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

Conf	conf;
Mach	machs[MAXMACH];
Mach	*m;
struct Active active;

void
portinit(uint64_t membase, uint64_t memsize)
{
	m = &machs[0];
	m->machno = 0;

	conf.nmach = 1;
	conf.nproc = 32;
	conf.base0 = membase;
	conf.npage0 = memsize / BY2PG;
	conf.npage = conf.npage0;
	conf.ialloc = 4096;
	conf.pipeqsize = 8 * 1024;

	consprint("infernode/amd64: port: ");
	consprintdec(conf.nmach);
	consprint(" cpu, ");
	consprintdec(conf.npage);
	consprint(" pages\n");
}
