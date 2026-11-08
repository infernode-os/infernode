/*
 * #r -- the real-time clock, by Plan 9's name for it: #r/rtc is seconds
 * since 1970, decimal, read or written. battery is new here: the coin
 * cell's voltage in millivolts, 6 or so when there is none.
 *
 * The clock itself is the firmware's: rtcfan.c.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

enum{
	Qdir,
	Qrtc,
	Qbattery,
};

static Dirtab rtctab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"rtc",		{Qrtc},			0,	0664,
	"battery",	{Qbattery},		0,	0444,
};

static Chan*
rtcattach(char *spec)
{
	return devattach('r', spec);
}

static Walkqid*
rtcwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, rtctab, nelem(rtctab), devgen);
}

static int
rtcstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, rtctab, nelem(rtctab), devgen);
}

static Chan*
rtcopen(Chan *c, int omode)
{
	return devopen(c, omode, rtctab, nelem(rtctab), devgen);
}

static void
rtcclose(Chan *c)
{
	USED(c);
}

static long
rtcread(Chan *c, void *a, long n, vlong off)
{
	char buf[32];

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, rtctab, nelem(rtctab), devgen);
	case Qrtc:
		snprint(buf, sizeof buf, "%lld\n", rtcget());
		return readstr(off, a, n, buf);
	case Qbattery:
		snprint(buf, sizeof buf, "%d\n", rtcbatt());
		return readstr(off, a, n, buf);
	}
	error(Egreg);
	return 0;
}

static long
rtcwrite(Chan *c, void *a, long n, vlong off)
{
	char buf[32];

	USED(off);
	if((ulong)c->qid.path != Qrtc)
		error(Eperm);
	if(n >= sizeof buf)
		error(Etoobig);
	memmove(buf, a, n);
	buf[n] = 0;
	if(rtcset(strtoul(buf, nil, 0)) < 0)
		error("firmware did not answer");
	return n;
}

Dev rtcdevtab = {
	'r',
	"rtc",

	devreset,
	devinit,
	devshutdown,
	rtcattach,
	rtcwalk,
	rtcstat,
	rtcopen,
	devcreate,
	rtcclose,
	rtcread,
	devbread,
	rtcwrite,
	devbwrite,
	devremove,
	devwstat,
};
