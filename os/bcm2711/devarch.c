/*
 * #P -- what the firmware knows about the chip's health, as files.
 *
 *	cputemp		the SoC's temperature now, degrees C ("51.2")
 *	maxtemp		where the firmware starts throttling, degrees C
 *	throttled	the firmware's flag word, in hex, and what it says:
 *			bits 0-3 are now (under-voltage, ARM clock capped,
 *			throttled, soft temperature limit), bits 16-19 the
 *			same since boot
 *
 * cputemp is 9front's name for the first, in the same device, so a
 * script that reads it there reads it here. Each read asks the firmware
 * again; nothing is cached and nothing polls.
 *
 * Read-only: the firmware's limits are set in config.txt (temp_limit),
 * not here.
 *
 * In os/bcm2711 and not ../bcm, although the mailbox tags are the same
 * on a BCM2837: a file in ../bcm is linked into the Pi 3B+'s kernel
 * too, and that kernel is not to change until it can be run.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"io.h"
#include	"board.h"

enum{
	Qdir,
	Qtemp,
	Qmaxtemp,
	Qthrottled,

	Taggettemp	= 0x00030006,
	Taggetmaxtemp	= 0x0003000a,
	Taggetthrottled	= 0x00030046,
};

static Dirtab archtab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"cputemp",	{Qtemp},		0,	0444,
	"maxtemp",	{Qmaxtemp},		0,	0444,
	"throttled",	{Qthrottled},		0,	0444,
};

static char *throttlebits[] = {
	"under-voltage",
	"arm-capped",
	"throttled",
	"soft-temp-limit",
};

/* tag 0x00030006 and 0x0003000a take an id (0) and answer id, millidegrees */
static u32int
millideg(u32int tag)
{
	u32int v[2];

	v[0] = 0;
	v[1] = 0;
	if(mboxprop(tag, v, 1, 2) < 0)
		error("firmware did not answer");
	return v[1];
}

static long
throttledread(void *a, long n, vlong off)
{
	char buf[256], *p, *e;
	u32int v[1];
	int i, any;

	v[0] = 0;
	if(mboxprop(Taggetthrottled, v, 1, 1) < 0)
		error("firmware did not answer");
	p = buf;
	e = buf + sizeof buf;
	p = seprint(p, e, "0x%.5ux", v[0]);
	any = 0;
	for(i = 0; i < nelem(throttlebits); i++)
		if(v[0] & 1<<i){
			p = seprint(p, e, " %s", throttlebits[i]);
			any = 1;
		}
	for(i = 0; i < nelem(throttlebits); i++)
		if(v[0] & 1<<(16+i)){
			p = seprint(p, e, " %s-since-boot", throttlebits[i]);
			any = 1;
		}
	if(!any)
		p = seprint(p, e, " ok");
	seprint(p, e, "\n");
	return readstr(off, a, n, buf);
}

static Chan*
archattach(char *spec)
{
	return devattach('P', spec);
}

static Walkqid*
archwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, archtab, nelem(archtab), devgen);
}

static int
archstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, archtab, nelem(archtab), devgen);
}

static Chan*
archopen(Chan *c, int omode)
{
	return devopen(c, omode, archtab, nelem(archtab), devgen);
}

static void
archclose(Chan *c)
{
	USED(c);
}

static long
archread(Chan *c, void *a, long n, vlong off)
{
	char buf[32];
	u32int t;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, archtab, nelem(archtab), devgen);
	case Qtemp:
	case Qmaxtemp:
		t = millideg((ulong)c->qid.path == Qtemp? Taggettemp: Taggetmaxtemp);
		snprint(buf, sizeof buf, "%ud.%ud\n", t/1000, (t%1000)/100);
		return readstr(off, a, n, buf);
	case Qthrottled:
		return throttledread(a, n, off);
	}
	error(Egreg);
	return 0;
}

static long
archwrite(Chan *c, void *a, long n, vlong off)
{
	USED(c); USED(a); USED(n); USED(off);
	error(Eperm);
	return 0;
}

Dev archdevtab = {
	'P',
	"arch",

	devreset,
	devinit,
	devshutdown,
	archattach,
	archwalk,
	archstat,
	archopen,
	devcreate,
	archclose,
	archread,
	devbread,
	archwrite,
	devbwrite,
	devremove,
	devwstat,
};
