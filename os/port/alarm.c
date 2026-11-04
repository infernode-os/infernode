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

/*
 * ^T^Ta: the timed sleepers, for a kernel whose sleepers no longer
 * wake: the list's lock (held, by whom), each sleeper and when it is
 * due, and each core's ticks.
 */
static void
alarmdump(void)
{
	Proc *p;
	int i, n;

	print("talarm: lock key %lud pc %#p by %lud, list %#p\n", talarm.l.key, talarm.l.pc,
		talarm.l.p != nil? ((Proc*)talarm.l.p)->pid: 0, talarm.list);
	n = 0;
	for(p = talarm.list; p != nil && n < 64; p = p->tlink, n++)
		print("  %lud:%s %s twhen %lud trend %#p\n", p->pid, p->text, statename[p->state], p->twhen, p->trend);
	for(i = 0; i < conf.nmach; i++)
		if(MACHP(i) != nil)
			print("  cpu%d ticks %lud\n", i, MACHP(i)->ticks);
}

void
alarminit(void)
{
	debugkey('a', "timed sleepers", alarmdump, 0);
}
