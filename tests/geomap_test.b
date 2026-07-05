implement GeoMapTest;

#
# geomap_test - projection round-trips and known anchor points for the
# geoproj library (the name-keyed projection core behind geo-map).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "math.m";
	math: Math;

include "geoproj.m";
	geoproj: Geoproj;
	Proj: import geoproj;

include "testing.m";
	testing: Testing;
	T: import testing;

GeoMapTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/geomap_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>	;
	"fail:skip" =>	;
	* =>	t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# absolute tolerance for real comparisons
close(a, b, tol: real): int
{
	d := a - b;
	if(d < 0.0) d = -d;
	return d <= tol;
}

testAnchors(t: ref T)
{
	m := geoproj->lookup("mercator");
	t.assert(m != nil, "mercator projection exists");
	t.assertseq(m.name, "mercator", "projection name");

	# (0,0) maps to the centre of the unit world.
	(x0, y0) := geoproj->fwd(m, 0.0, 0.0);
	t.assert(close(x0, 0.5, 0.0001), "lat0/lon0 -> x=0.5");
	t.assert(close(y0, 0.5, 0.0001), "lat0/lon0 -> y=0.5");

	# Longitude maps linearly: -180 -> 0, +180 -> 1.
	(xw, nil) := geoproj->fwd(m, 0.0, -180.0);
	(xe, nil) := geoproj->fwd(m, 0.0,  180.0);
	t.assert(close(xw, 0.0, 0.0001), "lon -180 -> x=0");
	t.assert(close(xe, 1.0, 0.0001), "lon +180 -> x=1");

	# Northern latitudes are in the upper half (smaller y).
	(nil, yn) := geoproj->fwd(m, 45.0, 0.0);
	t.assert(yn < 0.5, "north lat -> upper half");
}

testRoundTrip(t: ref T)
{
	m := geoproj->lookup("");		# default = mercator
	t.assert(m != nil, "default projection");
	lats := array[] of {0.0, 37.7749, -33.8688, 60.0, -60.0};
	lons := array[] of {0.0, -122.4194, 151.2093, 24.0, -100.0};
	for(i := 0; i < len lats; i++) {
		(x, y) := geoproj->fwd(m, lats[i], lons[i]);
		(la, lo) := geoproj->inv(m, x, y);
		t.assert(close(la, lats[i], 0.0001), "lat round-trips");
		t.assert(close(lo, lons[i], 0.0001), "lon round-trips");
	}
}

testEquirect(t: ref T)
{
	e := geoproj->lookup("equirect");
	t.assert(e != nil, "equirect projection exists");
	(x, y) := geoproj->fwd(e, 90.0, -180.0);
	t.assert(close(x, 0.0, 0.0001), "NW corner x=0");
	t.assert(close(y, 0.0, 0.0001), "NW corner y=0 (north=top)");
	(la, lo) := geoproj->inv(e, 1.0, 1.0);
	t.assert(close(la, -90.0, 0.0001), "SE corner lat=-90");
	t.assert(close(lo, 180.0, 0.0001), "SE corner lon=180");
}

testUnknown(t: ref T)
{
	t.assert(geoproj->lookup("nosuchproj") == nil, "unknown projection -> nil");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	geoproj = load Geoproj Geoproj->PATH;
	if(geoproj == nil) {
		sys->fprint(sys->fildes(2), "cannot load geoproj module: %r\n");
		raise "fail:cannot load geoproj";
	}
	geoproj->init();
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("Anchors", testAnchors);
	run("RoundTrip", testRoundTrip);
	run("Equirect", testEquirect);
	run("Unknown", testUnknown);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
