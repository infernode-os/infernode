/*
 * #g / `location` — the host's location service as an NMEA receiver.
 *
 *     #g/nmea      (r)  NMEA 0183 sentences, from the open on: an RMC,
 *                       a GST and a GGA for each fix the host gives.
 *                       Reads block.  The first open starts the host's
 *                       service, the last close stops it.
 *     #g/status    (r)  the service's state: unavailable (none on this
 *                       host), stopped, waiting (started, no fix yet),
 *                       ok, denied (permission refused), off (location
 *                       services disabled)
 *
 * A phone's location service gives positions, not sentences; they are
 * written here as a receiver would send them, so gpsfs(4) takes the
 * phone as it takes a serial receiver: `source '#g/nmea'`.  The
 * platform calls live in emu/<plat>/locationbridge.{c,m}
 * (locationbridge.h); this file owns the namespace and the sentences.
 *
 * Accuracy, a radius, is given in GST as equal latitude and longitude
 * errors whose root sum of squares is the radius; nmea(2) reads it
 * back as err.  The service says nothing of satellites, so GGA leaves
 * their number and the dilution empty.
 */

#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"locationbridge.h"

#define	QLIMIT	16384	/* per reader: about a minute of fixes */

enum
{
	Qdir,
	Qnmea,
	Qstatus,
};

static
Dirtab loctab[] =
{
	".",		{Qdir, 0, QTDIR},	0,	DMDIR|0555,
	"nmea",		{Qnmea, 0, 0},		0,	0444,
	"status",	{Qstatus, 0, 0},	0,	0444,
};

/*
 * One queue per open of nmea; a fix is produced onto every one.  The
 * lock is the port-style spin lock, taken by kprocs and by the
 * bridge's threads alike (as devphone's listeners).
 */
typedef struct Listener Listener;
struct Listener
{
	Queue	*q;
	Listener *next;
};

static Listener	*listeners;
static int	nlisteners;
static Lock	llock;
static QLock	startlock;	/* serialises start and stop */
static char	state[32] = "stopped";
static int	started;

void
locationbridge_post_state(const char *s)
{
	lock(&llock);
	if(started || strcmp(s, "unavailable") == 0)
		utfecpy(state, state+sizeof(state), (char*)s);
	unlock(&llock);
}

static int
nmeasum(char *s)
{
	int sum;

	sum = 0;
	for(s++; *s != 0 && *s != '*'; s++)
		sum ^= (uchar)*s;
	return sum;
}

/* append a sentence, its checksum and CRLF */
static char*
sentence(char *p, char *e, char *body)
{
	char *s;

	s = p;
	p = seprint(p, e, "$%s", body);
	return seprint(p, e, "*%.2X\r\n", nmeasum(s));
}

/* degrees as NMEA's d(dd)mm.mmmmm and its hemisphere */
static char*
angle(char *p, char *e, double v, int ndeg, int pos, int neg)
{
	int h;
	long long m;

	h = pos;
	if(v < 0){
		v = -v;
		h = neg;
	}
	m = (long long)(v * 60.0 * 100000.0 + 0.5);	/* hundred-thousandths of a minute */
	return seprint(p, e, "%.*d%.2d.%.5d,%c", ndeg, (int)(m / 6000000),
		(int)(m / 100000 % 60), (int)(m % 100000), h);
}

/* days since 1970-01-01 as a civil date (Hinnant's algorithm) */
static void
civil(long long days, int *y, int *m, int *d)
{
	long long z, era, doe, yoe, doy, mp;

	z = days + 719468;
	era = (z >= 0 ? z : z - 146096) / 146097;
	doe = z - era * 146097;
	yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
	doy = doe - (365*yoe + yoe/4 - yoe/100);
	mp = (5*doy + 2) / 153;
	*d = doy - (153*mp + 2)/5 + 1;
	*m = mp < 10 ? mp + 3 : mp - 9;
	*y = yoe + era * 400 + (*m <= 2);
}

void
locationbridge_post_fix(const LocFix *f)
{
	char buf[512], body[200], hms[16], dmy[8], *p, *e, *b, *be;
	long long t, days;
	int y, mo, d, s, cs;
	Listener *l;

	if(f->lat < -90 || f->lat > 90 || f->lon < -180 || f->lon > 180)
		return;
	t = f->utcms;
	days = t / 86400000;
	if(t < 0)
		return;
	s = (t % 86400000) / 1000;
	cs = (t % 1000) / 10;
	civil(days, &y, &mo, &d);
	snprint(hms, sizeof hms, "%.2d%.2d%.2d.%.2d", s/3600, s/60%60, s%60, cs);
	snprint(dmy, sizeof dmy, "%.2d%.2d%.2d", d, mo, y%100);

	p = buf;
	e = buf + sizeof buf;
	be = body + sizeof body;

	b = seprint(body, be, "GPRMC,%s,A,", hms);
	b = angle(b, be, f->lat, 2, 'N', 'S');
	b = seprint(b, be, ",");
	b = angle(b, be, f->lon, 3, 'E', 'W');
	b = seprint(b, be, ",");
	if(f->hasspeed && f->speed >= 0)
		b = seprint(b, be, "%.2f", f->speed * 3600.0 / 1852.0);
	b = seprint(b, be, ",");
	if(f->hascourse && f->course >= 0)
		b = seprint(b, be, "%.1f", f->course);
	seprint(b, be, ",%s,,,A", dmy);
	p = sentence(p, e, body);

	if(f->hacc >= 0 || f->vacc >= 0){
		b = seprint(body, be, "GPGST,%s,,,,,", hms);
		if(f->hacc >= 0)
			b = seprint(b, be, "%.1f,%.1f,", f->hacc/1.41421356, f->hacc/1.41421356);
		else
			b = seprint(b, be, ",,");
		if(f->vacc >= 0)
			seprint(b, be, "%.1f", f->vacc);
		p = sentence(p, e, body);
	}

	b = seprint(body, be, "GPGGA,%s,", hms);
	b = angle(b, be, f->lat, 2, 'N', 'S');
	b = seprint(b, be, ",");
	b = angle(b, be, f->lon, 3, 'E', 'W');
	b = seprint(b, be, ",1,,,");
	if(f->hasalt)
		b = seprint(b, be, "%.1f", f->alt);
	seprint(b, be, ",M,,M,,");
	p = sentence(p, e, body);

	lock(&llock);
	if(started)
		utfecpy(state, state+sizeof(state), "ok");
	for(l = listeners; l != nil; l = l->next)
		qproduce(l->q, buf, p - buf);
	unlock(&llock);
}

static void
locinit(void)
{
	locationbridge_init();
}

static Chan*
locattach(char *spec)
{
	return devattach('g', spec);
}

static Walkqid*
locwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, loctab, nelem(loctab), devgen);
}

static int
locstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, loctab, nelem(loctab), devgen);
}

static Chan*
locopen(Chan *c, int omode)
{
	Listener *l;
	Queue *q;
	char err[ERRMAX];

	c = devopen(c, omode, loctab, nelem(loctab), devgen);
	if((ulong)c->qid.path != Qnmea)
		return c;
	q = qopen(QLIMIT, 0, nil, nil);
	l = malloc(sizeof *l);
	if(q == nil || l == nil){
		if(q != nil)
			qfree(q);
		free(l);
		c->flag &= ~COPEN;
		error(Enomem);
	}
	l->q = q;
	qlock(&startlock);
	if(nlisteners == 0){
		err[0] = 0;
		lock(&llock);
		started = 1;
		utfecpy(state, state+sizeof(state), "waiting");
		unlock(&llock);
		if(locationbridge_start(err, sizeof err) < 0){
			lock(&llock);
			started = 0;
			utfecpy(state, state+sizeof(state), "unavailable");
			unlock(&llock);
			qunlock(&startlock);
			qfree(q);
			free(l);
			c->flag &= ~COPEN;
			error(err[0] ? err : "location unavailable");
		}
	}
	nlisteners++;
	lock(&llock);
	l->next = listeners;
	listeners = l;
	unlock(&llock);
	qunlock(&startlock);
	c->aux = q;
	return c;
}

static void
locclose(Chan *c)
{
	Listener **pp, *l;
	Queue *q;

	if((c->flag & COPEN) == 0 || (ulong)c->qid.path != Qnmea || c->aux == nil)
		return;
	q = c->aux;
	c->aux = nil;
	qlock(&startlock);
	lock(&llock);
	for(pp = &listeners; (l = *pp) != nil; pp = &l->next)
		if(l->q == q){
			*pp = l->next;
			free(l);
			break;
		}
	unlock(&llock);
	if(--nlisteners == 0){
		lock(&llock);
		started = 0;
		utfecpy(state, state+sizeof(state), "stopped");
		unlock(&llock);
		locationbridge_stop();
	}
	qunlock(&startlock);
	qhangup(q, nil);
	qfree(q);
}

static long
locread(Chan *c, void *va, long n, vlong offset)
{
	char buf[64];

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, loctab, nelem(loctab), devgen);
	switch((ulong)c->qid.path){
	case Qnmea:
		return qread(c->aux, va, n);
	case Qstatus:
		lock(&llock);
		snprint(buf, sizeof buf, "%s\n", state);
		unlock(&llock);
		return readstr(offset, va, n, buf);
	}
	error(Egreg);
	return 0;
}

static long
locwrite(Chan *c, void *va, long n, vlong offset)
{
	USED(c);
	USED(va);
	USED(n);
	USED(offset);
	error(Eperm);
	return 0;
}

Dev locationdevtab = {
	'g',
	"location",

	locinit,
	locattach,
	locwalk,
	locstat,
	locopen,
	devcreate,
	locclose,
	locread,
	devbread,
	locwrite,
	devbwrite,
	devremove,
	devwstat,
};
