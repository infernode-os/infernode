implement AAdraw;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "math.m";
	math: Math;
include "aadraw.m";

display: ref Display;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	display = d;
}

# Analytic edge coverage: distance from the pixel centre to the ideal
# shape edge, clamped over a one-pixel transition band.  Exact and
# smooth — supersampling a thin band beats (beads) against the sample
# lattice; distance never does.
cov01(d: real): byte
{
	v := 0.5 - d;		# d < -0.5 fully in, > 0.5 fully out
	if(v <= 0.0)
		return byte 0;
	if(v >= 1.0)
		return byte 255;
	return byte (int (v * 255.0));
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
	hw := real w / 2.0;	# stroke half-width
	for(i = 0; i < len pts - 1; i++) {
		x0 := real (pts[i].x - bb.min.x);   y0 := real (pts[i].y - bb.min.y);
		x1 := real (pts[i+1].x - bb.min.x); y1 := real (pts[i+1].y - bb.min.y);
		vx := x1 - x0; vy := y1 - y0;
		len2 := vx*vx + vy*vy;
		# per-segment sub-bbox keeps long polylines affordable
		lox := int (fmin(x0, x1) - hw - 2.0); if(lox < 0) lox = 0;
		loy := int (fmin(y0, y1) - hw - 2.0); if(loy < 0) loy = 0;
		hix := int (fmax(x0, x1) + hw + 2.0); if(hix >= W) hix = W - 1;
		hiy := int (fmax(y0, y1) + hw + 2.0); if(hiy >= H) hiy = H - 1;
		for(y := loy; y <= hiy; y++)
		for(x := lox; x <= hix; x++) {
			px := real x + 0.5; py := real y + 0.5;
			t := 0.0;
			if(len2 > 0.0) {
				t = ((px - x0)*vx + (py - y0)*vy) / len2;
				if(t < 0.0) t = 0.0;
				else if(t > 1.0) t = 1.0;
			}
			dx := px - (x0 + t*vx); dy := py - (y0 + t*vy);
			c := cov01(math->sqrt(dx*dx + dy*dy) - hw);
			if(c > cov[y*W+x])
				cov[y*W+x] = c;
		}
	}
	cover(dst, bb, src, cov);
}

fmin(a, b: real): real { if(a < b) return a; return b; }
fmax(a, b: real): real { if(a > b) return a; return b; }

ring(dst: ref Image, c: Point, a, b, w: int, src: ref Image)
{
	ell(dst, c, a, b, w, src);
}

disc(dst: ref Image, c: Point, a, b: int, src: ref Image)
{
	ell(dst, c, a, b, 0, src);
}

# Shared ellipse coverage: w > 0 hollows a ring of that width.
# Analytic: radial distance from the pixel centre to the edge, scaled
# to pixel units by the local radius — exact for circles, a good
# approximation for moderate ellipses.
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
	cx := real (c.x - bb.min.x); cy := real (c.y - bb.min.y);
	ra := real a; rb := real b;
	hw := real ow / 2.0;
	for(y := 0; y < H; y++)
	for(x := 0; x < W; x++) {
		dx := (real x + 0.5 - cx) / ra;
		dy := (real y + 0.5 - cy) / rb;
		rn := math->sqrt(dx*dx + dy*dy);
		# distance to the edge in pixels: (rn-1) * local radius
		scale := ra;
		if(rb < ra)
			scale = rb;
		d := (rn - 1.0) * scale;
		cv: byte;
		if(w == 0)
			cv = cov01(d);			# filled disc
		else {
			ad := d; if(ad < 0.0) ad = -ad;
			cv = cov01(ad - hw);		# ring band
		}
		if(cv > cov[y*W+x])
			cov[y*W+x] = cv;
	}
	cover(dst, bb, src, cov);
}
