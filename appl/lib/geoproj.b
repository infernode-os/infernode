implement Geoproj;

#
# geoproj — map projections as a name-keyed registry (see geoproj.m).
#
# Two projections to start, both trivial and exact:
#   mercator  — web mercator, the slippy-map standard; straight meridians
#               and parallels, conformal, clamped near the poles.
#   equirect  — plate carree; undistorted poles, cheapest possible.
#
# Adding another is one registry row plus one case in fwd/inv, exactly as
# Plan 9's libmap grows.
#

include "sys.m";
include "math.m";
	math: Math;
include "geoproj.m";

# Latitude where web mercator's y diverges; clamp to keep things finite.
MERCMAX: con 85.05112877980659;

Reg: adt { name: string; kind: int; };

registry := array[] of {
	Reg("mercator", Geoproj->MERCATOR),
	Reg("equirect", Geoproj->EQUIRECT),
};

init()
{
	math = load Math Math->PATH;
}

lookup(name: string): ref Geoproj->Proj
{
	if(name == "")
		name = "mercator";
	for(i := 0; i < len registry; i++)
		if(registry[i].name == name)
			return ref Geoproj->Proj(registry[i].name, registry[i].kind);
	return nil;
}

fwd(p: ref Geoproj->Proj, lat, lon: real): (real, real)
{
	case p.kind {
	Geoproj->EQUIRECT =>
		return ((lon + 180.0) / 360.0, (90.0 - lat) / 180.0);
	* =>	# mercator
		if(lat >  MERCMAX) lat =  MERCMAX;
		if(lat < -MERCMAX) lat = -MERCMAX;
		x := (lon + 180.0) / 360.0;
		y := 0.5 - math->asinh(math->tan(lat * Math->Degree)) / (2.0 * Math->Pi);
		return (x, y);
	}
}

inv(p: ref Geoproj->Proj, x, y: real): (real, real)
{
	case p.kind {
	Geoproj->EQUIRECT =>
		return (90.0 - y * 180.0, x * 360.0 - 180.0);
	* =>	# mercator
		lon := x * 360.0 - 180.0;
		lat := math->atan(math->sinh((0.5 - y) * 2.0 * Math->Pi)) / Math->Degree;
		return (lat, lon);
	}
}
