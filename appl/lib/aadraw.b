implement AAdraw;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "aadraw.m";

display: ref Display;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
}

# Blend src through a coverage mask over bb (cov is Dx*Dy bytes).
cover(dst: ref Image, bb: Rect, src: ref Image, cov: array of byte)
{
	if(src == nil || bb.dx() <= 0 || bb.dy() <= 0 || display == nil)
		return;
	m := display.newimage(Rect((0, 0), (bb.dx(), bb.dy())), Draw->GREY8, 0, Draw->Transparent);
	if(m == nil)
		return;
	m.writepixels(m.r, cov);
	dst.draw(bb, src, m, (0, 0));
}

clipbb(dst: ref Image, bb: Rect): Rect
{
	c := dst.clipr;
	if(bb.min.x < c.min.x) bb.min.x = c.min.x;
	if(bb.min.y < c.min.y) bb.min.y = c.min.y;
	if(bb.max.x > c.max.x) bb.max.x = c.max.x;
	if(bb.max.y > c.max.y) bb.max.y = c.max.y;
	return bb;
}

line(dst: ref Image, p0, p1: Point, w: int, src: ref Image)
{
	polyline(dst, array[] of {p0, p1}, w, src);
}

polyline(dst: ref Image, pts: array of Point, w: int, src: ref Image)
{
	if(len pts < 2)
		return;
	if(w < 1)
		w = 1;
	bb := Rect(pts[0], pts[0]);
	for(i := 1; i < len pts; i++) {
		if(pts[i].x < bb.min.x) bb.min.x = pts[i].x;
		if(pts[i].y < bb.min.y) bb.min.y = pts[i].y;
		if(pts[i].x > bb.max.x) bb.max.x = pts[i].x;
		if(pts[i].y > bb.max.y) bb.max.y = pts[i].y;
	}
	bb = clipbb(dst, bb.inset(-(w + 2)));
	W := bb.dx(); H := bb.dy();
	if(W <= 0 || H <= 0)
		return;
	cov := array[W*H] of { * => byte 0 };
	r8 := 4*w;	# half-width in 1/8th px (w px stroke → w/2 radius)
	if(r8 < 4)
		r8 = 4;
	r2 := r8*r8;
	for(i = 0; i < len pts - 1; i++) {
		x0 := 8*(pts[i].x - bb.min.x);   y0 := 8*(pts[i].y - bb.min.y);
		x1 := 8*(pts[i+1].x - bb.min.x); y1 := 8*(pts[i+1].y - bb.min.y);
		vx := x1 - x0; vy := y1 - y0;
		len2 := vx*vx + vy*vy;
		# per-segment sub-bbox keeps big polylines affordable
		sminx := x0; if(x1 < sminx) sminx = x1;
		sminy := y0; if(y1 < sminy) sminy = y1;
		smaxx := x0; if(x1 > smaxx) smaxx = x1;
		smaxy := y0; if(y1 > smaxy) smaxy = y1;
		lox := (sminx - r8 - 8)/8; if(lox < 0) lox = 0;
		loy := (sminy - r8 - 8)/8; if(loy < 0) loy = 0;
		hix := (smaxx + r8 + 8)/8; if(hix >= W) hix = W - 1;
		hiy := (smaxy + r8 + 8)/8; if(hiy >= H) hiy = H - 1;
		for(y := loy; y <= hiy; y++)
		for(x := lox; x <= hix; x++) {
			hit := 0;
			for(sy := 0; sy < 4; sy++)
			for(sx := 0; sx < 4; sx++) {
				px := 8*x + 2*sx + 1;
				py := 8*y + 2*sy + 1;
				t := (px - x0)*vx + (py - y0)*vy;
				if(t < 0) t = 0;
				else if(t > len2) t = len2;
				qx: int; qy: int;
				if(len2 > 0) {
					qx = x0 + int (big t * big vx / big len2);
					qy = y0 + int (big t * big vy / big len2);
				} else {
					qx = x0; qy = y0;
				}
				dx := px - qx; dy := py - qy;
				if(dx*dx + dy*dy <= r2)
					hit++;
			}
			c := hit*255/16;
			if(byte c > cov[y*W+x])
				cov[y*W+x] = byte c;
		}
	}
	cover(dst, bb, src, cov);
}

ring(dst: ref Image, c: Point, a, b, w: int, src: ref Image)
{
	ell(dst, c, a, b, w, src);
}

disc(dst: ref Image, c: Point, a, b: int, src: ref Image)
{
	ell(dst, c, a, b, 0, src);
}

# Shared ellipse coverage: w > 0 hollows a ring of that width.
ell(dst: ref Image, c: Point, a, b, w: int, src: ref Image)
{
	if(a < 1 || b < 1)
		return;
	ow := w;
	if(ow < 0)
		ow = 0;
	bb := clipbb(dst, Rect((c.x - a, c.y - b), (c.x + a, c.y + b)).inset(-(ow + 2)));
	W := bb.dx(); H := bb.dy();
	if(W <= 0 || H <= 0)
		return;
	cov := array[W*H] of { * => byte 0 };
	cx8 := 8*(c.x - bb.min.x); cy8 := 8*(c.y - bb.min.y);
	a8 := big (8*a + 4*ow); b8 := big (8*b + 4*ow);
	ia8 := a8 - big (8*ow); ib8 := b8 - big (8*ow);
	if(w == 0) { ia8 = big 0; ib8 = big 0; }
	if(ia8 < big 0) ia8 = big 0;
	if(ib8 < big 0) ib8 = big 0;
	a2 := a8*a8; b2 := b8*b8;
	ia2 := ia8*ia8; ib2 := ib8*ib8;
	for(y := 0; y < H; y++)
	for(x := 0; x < W; x++) {
		hit := 0;
		for(sy := 0; sy < 4; sy++)
		for(sx := 0; sx < 4; sx++) {
			fx := big (8*x + 2*sx + 1 - cx8);
			fy := big (8*y + 2*sy + 1 - cy8);
			qx := fx*fx; qy := fy*fy;
			if(qx*b2 + qy*a2 > a2*b2)
				continue;
			if(ia2 > big 0 && ib2 > big 0 && qx*ib2 + qy*ia2 <= ia2*ib2)
				continue;
			hit++;
		}
		cov[y*W+x] = byte (hit*255/16);
	}
	cover(dst, bb, src, cov);
}
