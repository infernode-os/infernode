/*
 * locationbridge — hosts with no location service (desktops).
 *
 * #o is there, and says unavailable.  For tests, and for trying a
 * map on a desk, $INFERNODE_LOCATION_FAKE, read when the emulator
 * starts, gives a service that reports a fix a second:
 *
 *	INFERNODE_LOCATION_FAKE='lat lon [alt [accuracy]]'
 *
 * degrees, metres above sea level and metres; the position moves
 * north a metre with each fix, at a metre a second, so a reader sees
 * it change.  A desktop that wants a real position mounts a phone's
 * /mnt/gps, or runs gpsfs on a receiver of its own.
 */

#include	"dat.h"
#include	"fns.h"
#include	"locationbridge.h"

static LocFix	fake;
static int	hasfake;
static int	gen;	/* the running fake's generation; a stop ends it */

void
locationbridge_init(void)
{
	char buf[128], *s, *f[4];	/* Flawfinder: ignore — buf filled only after strlen(s) < sizeof buf */
	int n;
	size_t l;

	/* four numbers: anything longer is not one, and is refused */
	s = getenv("INFERNODE_LOCATION_FAKE");	/* Flawfinder: ignore — the user's own setting for tests; length checked, fields parsed by strtod */
	if(s == nil || (l = strlen(s)) >= sizeof buf){	/* Flawfinder: ignore — getenv's string is NUL-terminated */
		locationbridge_post_state("unavailable");
		return;
	}
	memmove(buf, s, l+1);
	n = getfields(buf, f, nelem(f), 1, " \t");
	if(n < 2){
		locationbridge_post_state("unavailable");
		return;
	}
	fake.lat = strtod(f[0], nil);
	fake.lon = strtod(f[1], nil);
	if(n > 2){
		fake.hasalt = 1;
		fake.alt = strtod(f[2], nil);
	}
	fake.hacc = n > 3 ? strtod(f[3], nil) : -1;
	fake.vacc = -1;
	fake.hasspeed = 1;
	fake.speed = 1.0;
	fake.hascourse = 1;
	fake.course = 0.0;
	hasfake = 1;
}

static void
fakeproc(void *a)
{
	int g;
	LocFix f;

	g = (int)(uintptr)a;
	f = fake;
	while(g == gen){
		f.utcms = osusectime() / 1000;
		locationbridge_post_fix(&f);
		f.lat += 1.0 / 111320.0;	/* a metre */
		osmillisleep(1000);
	}
	pexit("", 0);
}

int
locationbridge_start(char *err, int errlen)
{
	if(!hasfake){
		snprint(err, errlen, "no location service on this host");
		return -1;
	}
	gen++;
	kproc("locfake", fakeproc, (void*)(uintptr)gen, 0);
	return 0;
}

void
locationbridge_stop(void)
{
	gen++;
}
