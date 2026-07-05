#
# geoproj.m — map projections as a small name-keyed registry.
#
# The Plan 9 libmap idea, in Limbo: a projection is a named kind, and
# fwd/inv map WGS84 lat/lon (degrees) to a unit world square [0,1]x[0,1]
# and back.  x runs east from -180, y runs south from +90 (so screen-y
# and world-y share a sense).  A renderer looks a projection up once by
# name and then calls fwd/inv per point.
#
# (Dispatch is by an integer kind rather than stored function pointers:
# Limbo function references held in an adt across a module boundary are
# fragile, and a switch is just as minimal and extends the same way —
# one registry row plus one case per projection.)
#

Geoproj: module
{
	PATH:	con "/dis/lib/geoproj.dis";

	MERCATOR, EQUIRECT: con iota;	# projection kinds

	Proj: adt
	{
		name:	string;
		kind:	int;
	};

	init:	fn();

	# Look up a projection by name; nil if unknown.  "" yields the
	# default (web mercator, the slippy-map standard).
	lookup:	fn(name: string): ref Proj;

	fwd:	fn(p: ref Proj, lat, lon: real): (real, real);	# (lat,lon deg) -> (x,y) in [0,1]
	inv:	fn(p: ref Proj, x, y: real): (real, real);	# (x,y) in [0,1] -> (lat,lon deg)
};
