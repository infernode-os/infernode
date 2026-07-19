#
# aadraw — anti-aliased geometry for Limbo Draw clients.
#
# Coverage masks blended exactly as glyphs are: GREY8 coverage is
# computed by integer supersampling (the same algorithm as libtk's
# tkaacov* C helpers) and drawn through as a matte.  The compositor
# always could blend coverage; the primitives never generated any —
# this module closes that gap for pixel modules (geo-map routes and
# rings, gauges, any Draw client).
#
AAdraw: module
{
	PATH:	con "/dis/lib/aadraw.dis";

	init:	fn(d: ref Draw->Display);

	# stroke with round caps and joins, width w pixels (>= 1)
	line:		fn(dst: ref Draw->Image, p0, p1: Draw->Point, w: int, src: ref Draw->Image);
	polyline:	fn(dst: ref Draw->Image, pts: array of Draw->Point, w: int, src: ref Draw->Image);

	# ellipse ring (outline width w) and filled disc, semi-axes a,b
	ring:	fn(dst: ref Draw->Image, c: Draw->Point, a, b, w: int, src: ref Draw->Image);
	disc:	fn(dst: ref Draw->Image, c: Draw->Point, a, b: int, src: ref Draw->Image);
};
