/*
 * #b -- the apparatus for measuring things honestly.
 *
 * Provides the $Bench builtin module described in module/bench.m, which
 * is the interface Vita Nuova's "Reliable Benchmarking with Limbo on
 * Inferno" (1999, revised 2000) is written against. Limbo otherwise has
 * only sys->millisec(), and a millisecond is far too coarse to measure
 * anything worth measuring on a machine that executes millions of
 * instructions inside one.
 *
 * NOT upstream's devbench.c. That one reads the x86 timestamp counter
 * through archrdtsc() and carries a thousand lines of built-in
 * benchmark suite besides. What is worth having is the INTERFACE -- so
 * that benchmark code written against the standard module runs here
 * unchanged -- backed by this board's own counter.
 *
 * The two things it offers are the two things a measurement needs:
 *
 *   microsec()  a timestamp fine enough to see the thing being timed.
 *
 *   disablegc() a way to stop the garbage collector from landing in
 *   enablegc()  the middle of a sample. A GC pause is not part of what
 *               is being measured and shows up as an outlier that is
 *               indistinguishable from a real one -- which is exactly
 *               the sort of thing that makes a benchmark unreliable
 *               rather than merely wrong.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	<interp.h>
#include	"io.h"
#include	"../port/error.h"
#include	<isa.h>
#include	"kernel.h"

#include	"bench.h"
#include	"benchmod.h"

enum{
	Qdir,
	Qusec,
};

static Dirtab benchtab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"busec",	{Qusec},		0,	0444,
};

/*
 * Where the clock is read from, and why the counter and not the tick.
 *
 * m->ticks counts scheduler ticks at HZ -- 100 a second, so 10ms of
 * granularity, which is worse than the millisecond we already had.
 * fastticks() reads the ARM generic timer counter directly, which runs
 * at 19.2MHz on this board: about 52ns a step, and monotonic.
 */
static uvlong
usec(void)
{
	uvlong hz, t;

	t = fastticks(&hz);
	if(hz == 0)
		return 0;
	return t / (hz / 1000000);
}

/*
 * The zero point.
 *
 * Timestamps are relative to a reset rather than absolute, so that the
 * numbers a benchmark prints are small enough to read and subtract
 * without thinking about the epoch.
 */
static uvlong benchbase;

void
Bench_microsec(void *fp)
{
	F_Bench_microsec *f;

	f = fp;
	*f->ret = (WORD)(usec() - benchbase);
}

void
Bench_reset(void *fp)
{
	USED(fp);
	benchbase = usec();
}

/*
 * Read, as the standard module defines it.
 *
 * Present because bench.m declares it and code written against the
 * interface may call it; it does what an ordinary read does. The
 * upstream device used this to hand back a captured trace, which is
 * part of the built-in suite this deliberately does not have.
 */
void
Bench_read(void *fp)
{
	F_Bench_read *f;

	f = fp;
	*f->ret = 0;
	USED(f);
}

/*
 * Hold the collector off for the duration of a sample.
 *
 * gclock/gcunlock are a COUNTER (gchalt), not a flag, so nesting is
 * safe and a benchmark that forgets to re-enable only suspends
 * collection until it exits rather than corrupting anything.
 */
void
Bench_disablegc(void *fp)
{
	USED(fp);
	gclock();
}

void
Bench_enablegc(void *fp)
{
	USED(fp);
	gcunlock();
}

static void
benchreset(void)
{
	builtinmod("$Bench", Benchmodtab, Benchmodlen);
}

static Chan*
benchattach(char *spec)
{
	return devattach('b', spec);
}

static Walkqid*
benchwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, benchtab, nelem(benchtab), devgen);
}

static int
benchstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, benchtab, nelem(benchtab), devgen);
}

static Chan*
benchopen(Chan *c, int omode)
{
	return devopen(c, omode, benchtab, nelem(benchtab), devgen);
}

static void
benchclose(Chan *c)
{
	USED(c);
}

/*
 * /dev/busec, so the clock is reachable as a file too.
 *
 * The module is what a benchmark uses; this is what a person uses from
 * a shell to see whether the thing is working at all.
 */
static long
benchread(Chan *c, void *a, long n, vlong off)
{
	char buf[32];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, benchtab, nelem(benchtab), devgen);
	if((ulong)c->qid.path != Qusec)
		error(Ebadusefd);

	snprint(buf, sizeof buf, "%lld", (vlong)(usec() - benchbase));
	return readstr(off, a, n, buf);
}

static long
benchwrite(Chan*, void*, long, vlong)
{
	error(Eperm);
	return 0;
}

Dev benchdevtab = {
	'b',
	"bench",

	benchreset,
	devinit,
	devshutdown,
	benchattach,
	benchwalk,
	benchstat,
	benchopen,
	devcreate,
	benchclose,
	benchread,
	devbread,
	benchwrite,
	devbwrite,
	devremove,
	devwstat,
};
