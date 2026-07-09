implement GeoFixture;

#
# geo-fixture — a Matrix service that writes a synthetic geo tree so
# the geo-map module is demoable in stock InferNode with no live data
# source: pure test data.
#
# It writes the /mnt/geo contract (docs/geo-map-design.md) as flat files
# under its outdir — the established Matrix service→outdir idiom:
#
#   <outdir>/entities/<id>   ndb stanza, rewritten each tick as units move
#   <outdir>/features/<id>   ndb stanza, drawn graphics (written once)
#
# Place names are neutral (San Francisco Bay); affiliations exercise the
# abstract friend/hostile/neutral/unknown palette.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "matrix.m";

GeoFixture: module
{
	init:	fn(mount: string, outdir: string): string;
	run:	fn();
	shutdown:	fn();
};

outdir_g:	string;
running:	int;
POLL_MS:	con 1000;

Unit: adt
{
	id:	string;
	lat, lon: real;
	affil:	string;
	kind:	string;
	course:	real;	# degrees true
	speed:	real;	# m/s
};

units:	array of ref Unit;

init(nil: string, outdir: string): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	outdir_g = outdir;
	mkdir(outdir + "/entities");
	mkdir(outdir + "/features");

	units = array[] of {
		ref Unit("ALPHA-6",  37.8100, -122.4100, "friend",  "ground", 70.0, 6.0),
		ref Unit("ROTOR-1",  37.8300, -122.3700, "friend",  "air",    250.0, 45.0),
		ref Unit("FERRY-9",  37.7950, -122.3900, "neutral", "sea",    300.0, 9.0),
		ref Unit("UNK-7",    37.7800, -122.4300, "unknown", "ground", 10.0, 2.0),
		ref Unit("HOSTILE-2",37.7700, -122.4000, "hostile", "ground", 150.0, 4.0),
	};
	writefeatures();
	return nil;
}

run()
{
	running = 1;
	while(running) {
		for(i := 0; i < len units; i++) {
			advance(units[i], real POLL_MS / 1000.0);
			writeunit(units[i]);
		}
		sys->sleep(POLL_MS);
	}
}

shutdown()
{
	running = 0;
}

# Advance a unit along its course; wrap a wide box so the demo loops.
advance(u: ref Unit, dt: real)
{
	a := u.course * Math->Degree;
	mlat := 111320.0;
	mlon := 111320.0 * math->cos(u.lat * Math->Degree);
	u.lat += u.speed * math->cos(a) * dt / mlat;
	u.lon += u.speed * math->sin(a) * dt / mlon;
	if(u.lat > 37.86) u.lat = 37.74;
	if(u.lat < 37.74) u.lat = 37.86;
	if(u.lon > -122.34) u.lon = -122.46;
	if(u.lon < -122.46) u.lon = -122.34;
}

writeunit(u: ref Unit)
{
	s := sys->sprint("id=%s\nlat=%.6f\nlon=%.6f\naffil=%s\nkind=%s\nlabel=%s\ncourse=%g\nspeed=%g\n",
		u.id, u.lat, u.lon, u.affil, u.kind, u.id, u.course, u.speed);
	writefile(outdir_g + "/entities/" + u.id, s);
}

writefeatures()
{
	# An area (polygon), a route (polyline), and a range ring (circle).
	writefile(outdir_g + "/features/AO-BRAVO",
		"id=AO-BRAVO\ntype=polygon\n" +
		"points=37.800,-122.430 37.820,-122.400 37.805,-122.370 37.785,-122.395\n" +
		"color=F2C14EFF\nfill=F2C14E30\nwidth=2\nlabel=AO BRAVO\n");
	writefile(outdir_g + "/features/ROUTE-1",
		"id=ROUTE-1\ntype=polyline\n" +
		"points=37.775,-122.450 37.790,-122.420 37.805,-122.405 37.825,-122.380\n" +
		"color=35C7FFFF\nwidth=2\nlabel=ROUTE 1\n");
	writefile(outdir_g + "/features/RING-1",
		"id=RING-1\ntype=circle\n" +
		"points=37.800,-122.405\nradius=800\ncolor=5BE37AFF\nwidth=1\nlabel=RING\n");
}

mkdir(path: string)
{
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r775);
	fd = nil;
}

writefile(path, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil)
		return;
	b := array of byte content;
	sys->write(fd, b, len b);
}
