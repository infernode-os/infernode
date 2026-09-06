/*
 * Imported from upstream Inferno os/port/alarm.c.
 *
 * DIVERGENCE FROM UPSTREAM: Talarm's embedded Lock is named.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

Talarm	talarm;

/*
 *  called every clock tick
 */
void
checkalarms(void)
{
	Proc *p;
	ulong now;

	now = MACHP(0)->ticks;

	if(talarm.list == 0 || canlock(&talarm.l) == 0)
		return;

	for(;;) {
		p = talarm.list;
		if(p == 0)
			break;

		if(p->twhen == 0) {
			talarm.list = p->tlink;
			p->trend = 0;
			continue;
		}
		if(now < p->twhen)
			break;
		wakeup(p->trend);
		talarm.list = p->tlink;
		p->trend = 0;
	}

	unlock(&talarm.l);
}
