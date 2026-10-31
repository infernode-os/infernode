#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "pool.h"
#include <math.h>

/*
 * aatest: checks of the anti-aliased rasteriser (aa.c, aapath.c)
 * against answers known in advance: exact coverage of shapes with
 * edges on known fractions, area totals, fill rules, the winding of
 * strokes, and that clipping or tiling never changes a pixel.
 * A test program, like drawtest.c: not part of the library.
 *
 * Built and run by tests/host/aa_test.sh.
 */

int	drawdebug;
int	failed;

/* what the emulator provides the library: images come from the C heap here */
Pool	*imagmem;
void*	poolalloc(Pool *p, ulong n) { USED(p); return malloc(n); }
void	poolfree(Pool *p, void *v) { USED(p); free(v); }
char*	poolname(Pool *p) { USED(p); return "image"; }
void	poolsetcompact(Pool *p, void (*f)(void*, void*)) { USED(p); USED(f); }
void*	mallocz(ulong n, int clr) { void *v = malloc(n); if(v != nil && clr) memset(v, 0, n); return v; }
void	_assert(char *s) { sysfatal("assert failed: %s", s); }
int	_tas(int *p) { int v = *p; *p = 1; return v; }
/* libdraw/path.c is built in to test its encoding; nothing is sent */
uchar*	bufimage(Display *d, int n) { USED(d); USED(n); return nil; }
void	_setdrawop(Display *d, Drawop op) { USED(d); USED(op); }
int	_drawprint(int fd, char *fmt, ...) { USED(fd); USED(fmt); return 0; }

#define	RND()	(seed = seed*1103515245 + 12345, (seed >> 8) & 0xFFFF)
#define	F(x)	((int)((x)*Aaone))	/* pixels to fixed point */

static void
fail(char *fmt, ...)
{
	va_list arg;
	char buf[256];

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof buf, fmt, arg);
	va_end(arg);
	print("FAIL: %s\n", buf);
	failed++;
}

static ulong	rgbatocolour(Memimage*, ulong);

static Memimage*
canvas(int w, int h)
{
	Memimage *m;

	m = allocmemimage(Rect(0, 0, w, h), GREY8);
	if(m == nil)
		sysfatal("allocmemimage: %r");
	memfillcolor(m, DBlack);
	return m;
}

static int
px(Memimage *m, int x, int y)
{
	return *byteaddr(m, Pt(x, y));
}

static void
fill(Memimage *m, Aapath *p, int wind)
{
	Aapoly poly;

	aapolyinit(&poly);
	aafill(&poly, p);
	memaadraw(m, &poly, wind, memwhite, Pt(0, 0), SoverD);
	aapolyfree(&poly);
}

static void
rect(Aapath *p, double x0, double y0, double x1, double y1)
{
	aamoveto(p, Pt(F(x0), F(y0)));
	aalineto(p, Pt(F(x1), F(y0)));
	aalineto(p, Pt(F(x1), F(y1)));
	aalineto(p, Pt(F(x0), F(y1)));
	aaclosepath(p);
}

static long
total(Memimage *m)
{
	long t;
	int x, y;

	t = 0;
	for(y = m->r.min.y; y < m->r.max.y; y++)
		for(x = m->r.min.x; x < m->r.max.x; x++)
			t += px(m, x, y);
	return t;
}

/* A rectangle with edges on quarter pixels: every pixel's coverage is exact. */
static void
testrect(void)
{
	Memimage *m;
	Aapath p;
	int x, y, want;
	double cx, cy;

	m = canvas(20, 20);
	aapathinit(&p);
	rect(&p, 2.25, 3.5, 7.75, 9.0);
	fill(m, &p, ~0);
	for(y = 0; y < 20; y++)
		for(x = 0; x < 20; x++){
			cx = (x < 2 || x > 7) ? 0 : (x == 2) ? 0.75 : (x == 7) ? 0.75 : 1;
			cy = (y < 3 || y > 8) ? 0 : (y == 3) ? 0.5 : 1;
			want = (int)(cx*cy*255 + 0.5);
			if(px(m, x, y) != want)
				fail("rect: pixel %d,%d is %d, want %d", x, y, px(m, x, y), want);
		}
	aapathfree(&p);
	freememimage(m);
}

/* The area of a circle, and its symmetry. */
static void
testcircle(void)
{
	Memimage *m;
	Aapath p;
	double area, want;
	int x, y;

	m = canvas(100, 100);
	aapathinit(&p);
	aaellipse(&p, Pt(F(50), F(50)), F(30), F(30));
	fill(m, &p, ~0);
	area = total(m)/255.0;
	want = 3.14159265*30*30;
	if(area < want*0.999 || area > want*1.001)
		fail("circle: area %d, want %d", (int)area, (int)want);
	for(y = 0; y < 100; y++)
		for(x = 0; x < 100; x++)
			if(abs(px(m, x, y) - px(m, 99-x, y)) > 1 || abs(px(m, x, y) - px(m, x, 99-y)) > 1)
				fail("circle: not symmetric at %d,%d", x, y);
	aapathfree(&p);
	freememimage(m);
}

/* Fill rules: a square inside a square, both wound the same way. */
static void
testrules(void)
{
	Memimage *m;
	Aapath p;

	aapathinit(&p);
	rect(&p, 2, 2, 18, 18);
	rect(&p, 6, 6, 14, 14);
	m = canvas(20, 20);
	fill(m, &p, ~0);
	if(px(m, 10, 10) != 255 || px(m, 3, 3) != 255 || px(m, 0, 0) != 0)
		fail("non-zero: %d %d %d", px(m, 10, 10), px(m, 3, 3), px(m, 0, 0));
	memfillcolor(m, DBlack);
	fill(m, &p, 1);
	if(px(m, 10, 10) != 0 || px(m, 3, 3) != 255)
		fail("even-odd: %d %d", px(m, 10, 10), px(m, 3, 3));
	aapathfree(&p);
	freememimage(m);
}

static void
strokeit(Memimage *m, Aapath *p, double w, int cap, int join)
{
	Aapoly poly;

	aapolyinit(&poly);
	aastroke(&poly, p, F(w), cap, cap, join, F(4));
	memaadraw(m, &poly, ~0, memwhite, Pt(0, 0), SoverD);
	aapolyfree(&poly);
}

/*
 * Strokes: a horizontal line on pixel centres is exactly its pixels;
 * crossing strokes in one path leave no hole; every cap and join is
 * wound the same way (a hole would show as a gap).
 */
static void
teststrokes(void)
{
	Memimage *m;
	Aapath p;
	int x, y, cap, join;
	double a, want;

	m = canvas(40, 40);
	aapathinit(&p);
	aamoveto(&p, Pt(F(5.0), F(10.5)));
	aalineto(&p, Pt(F(30.0), F(10.5)));
	strokeit(m, &p, 1, Capbutt, Joinmiter);
	for(x = 0; x < 40; x++)
		for(y = 0; y < 40; y++)
			if(px(m, x, y) != ((y == 10 && x >= 5 && x < 30) ? 255 : 0))
				fail("thin line: pixel %d,%d is %d", x, y, px(m, x, y));
	aapathfree(&p);

	for(cap = Capbutt; cap <= Capsquare; cap++)
	for(join = Joinmiter; join <= Joinbevel; join++){
		memfillcolor(m, DBlack);
		aapathinit(&p);
		aamoveto(&p, Pt(F(5), F(20)));
		aalineto(&p, Pt(F(35), F(20)));
		aamoveto(&p, Pt(F(20), F(5)));
		aalineto(&p, Pt(F(20), F(35)));
		aamoveto(&p, Pt(F(6), F(6)));	/* a zig-zag, turning both ways */
		aalineto(&p, Pt(F(14), F(12)));
		aalineto(&p, Pt(F(8), F(16)));
		aalineto(&p, Pt(F(16), F(30)));
		aamoveto(&p, Pt(F(30), F(30)));	/* a dot */
		aalineto(&p, Pt(F(30), F(30)));
		strokeit(m, &p, 5, cap, join);
		for(y = 18; y < 22; y++)
			for(x = 18; x < 22; x++)
				if(px(m, x, y) != 255)
					fail("cap %d join %d: crossing pixel %d,%d is %d", cap, join, x, y, px(m, x, y));
		if(px(m, 14, 12) == 0 || px(m, 8, 16) == 0 || px(m, 10, 11) == 0)
			fail("cap %d join %d: gap at a join", cap, join);
		if(cap != Capbutt && px(m, 30, 30) != 255)
			fail("cap %d: no dot", cap);
		if(cap == Capbutt && px(m, 30, 30) != 0)
			fail("butt dot drawn");
		aapathfree(&p);
	}

	/* a ring: a closed circle stroked, its area 2πrw */
	memfillcolor(m, DBlack);
	aapathinit(&p);
	aaellipse(&p, Pt(F(20), F(20)), F(12), F(12));
	strokeit(m, &p, 2, Capbutt, Joinround);
	a = total(m)/255.0;
	want = 2*3.14159265*12*2;
	if(a < want*0.995 || a > want*1.005)
		fail("ring: area %d, want %d", (int)a, (int)want);
	if(px(m, 20, 20) != 0)
		fail("ring: the middle is filled");
	aapathfree(&p);
	freememimage(m);
}

/*
 * Round-joined strokes against a reference: the stroke is the set of
 * points within half the width of the path, sampled 16×16 in each
 * pixel.  Any fault in how the outline is built (a hole, a loop outside
 * the stroke, coverage counted twice) shows as a difference.
 */
static double
segdist2(double px, double py, double ax, double ay, double bx, double by)
{
	double dx, dy, t, l2;

	dx = bx - ax;
	dy = by - ay;
	l2 = dx*dx + dy*dy;
	t = 0;
	if(l2 > 0)
		t = ((px-ax)*dx + (py-ay)*dy)/l2;
	if(t < 0)
		t = 0;
	if(t > 1)
		t = 1;
	dx = ax + t*dx - px;
	dy = ay + t*dy - py;
	return dx*dx + dy*dy;
}

static int
segsclose(double *x, double *y, int i, int j, double lim)
{
	/* the closest approach of segments i and j, sampled finely */
	int k;
	double t, px, py;

	for(k = 0; k <= 64; k++){
		t = k/64.0;
		px = x[i] + t*(x[i+1]-x[i]);
		py = y[i] + t*(y[i+1]-y[i]);
		if(segdist2(px, py, x[j], y[j], x[j+1], y[j+1]) < lim*lim)
			return 1;
		px = x[j] + t*(x[j+1]-x[j]);
		py = y[j] + t*(y[j+1]-y[j]);
		if(segdist2(px, py, x[i], y[i], x[i+1], y[i+1]) < lim*lim)
			return 1;
	}
	return 0;
}

/* a random open path whose stroke of half-width hw does not overlap itself */
static int
openpath(double *x, double *y, int *np, double hw, ulong *seedp)
{
	ulong seed;
	int i, j, n, tries;
	double ux, uy, vx, vy, c;

	seed = *seedp;
	for(tries = 0; tries < 200; tries++){
		n = 2 + RND()%5;
		for(i = 0; i < n; i++){
			x[i] = 6 + (RND()%3600)/100.0;
			y[i] = 6 + (RND()%3600)/100.0;
		}
		for(i = 0; i+1 < n; i++)
			if(hypot(x[i+1]-x[i], y[i+1]-y[i]) < 4*hw + 2)
				goto Again;
		/*
		 * No turn sharper than 120°: segments at least 4hw long then
		 * always have room for the exact inner corner (hw·tan(θ/2)
		 * back along each), and sharper turns on shorter segments
		 * pivot, with the conflation that brings.
		 */
		for(i = 1; i+1 < n; i++){
			ux = x[i]-x[i-1]; uy = y[i]-y[i-1];
			vx = x[i+1]-x[i]; vy = y[i+1]-y[i];
			c = (ux*vx + uy*vy)/(hypot(ux, uy)*hypot(vx, vy));
			if(c < -0.5)
				goto Again;
		}
		for(i = 0; i+1 < n; i++)
			for(j = i+2; j+1 < n; j++)
				if(segsclose(x, y, i, j, 2*hw + 2))
					goto Again;
		*np = n;
		*seedp = seed;
		return 1;
	Again:;
	}
	*seedp = seed;
	return 0;
}

static void
testreference(void)
{
	Memimage *m;
	Aapath p;
	double x[8], y[8], hw, sx, sy, d, e, maxerr, toterr;
	int i, n, k, px_, py_, sxi, syi, in, ref, trial, closed;
	ulong seed;

	seed = 12345;
	m = canvas(48, 48);
	maxerr = 0;
	for(trial = 0; trial < 60; trial++){
		/*
		 * Paths that do not overlap themselves: where a stroke
		 * crosses or doubles back on itself, both edges add coverage
		 * to the pixels they share (the conflation every exact-area
		 * rasteriser has), which this reference does not model.
		 */
		hw = (1 + RND()%700/100.0)/2;
		closed = trial%3 == 0;
		if(closed){	/* a convex polygon */
			n = 3 + RND()%5;
			for(i = 0; i < n; i++){
				d = 2*3.14159265*(i + (RND()%60)/100.0)/n;
				e = 10 + RND()%800/100.0;
				x[i] = 24 + e*cos(d);
				y[i] = 24 + e*sin(d);
			}
		}else if(!openpath(x, y, &n, hw, &seed))
			continue;
		memfillcolor(m, DBlack);
		aapathinit(&p);
		aamoveto(&p, Pt(F(x[0]), F(y[0])));
		for(i = 1; i < n; i++)
			aalineto(&p, Pt(F(x[i]), F(y[i])));
		if(closed)
			aaclosepath(&p);
		strokeit(m, &p, 2*hw, Capround, Joinround);
		aapathfree(&p);
		toterr = 0;
		for(py_ = 0; py_ < 48; py_++)
		for(px_ = 0; px_ < 48; px_++){
			in = 0;
			for(syi = 0; syi < 16; syi++)
			for(sxi = 0; sxi < 16; sxi++){
				sx = px_ + (sxi + 0.5)/16;
				sy = py_ + (syi + 0.5)/16;
				for(k = 0; k+1 < n + closed; k++){
					d = segdist2(sx, sy, x[k], y[k], x[(k+1)%n], y[(k+1)%n]);
					if(d <= hw*hw){
						in++;
						break;
					}
				}
			}
			ref = (in*255 + 128)/256;
			e = abs(px(m, px_, py_) - ref);
			toterr += px(m, px_, py_) - ref;
			if(e > maxerr)
				maxerr = e;
			if(e > 10)
				fail("reference trial %d (n %d closed %d hw %d/100): pixel %d,%d is %d, want %d",
					trial, n, closed, (int)(hw*100), px_, py_, px(m, px_, py_), ref);
		}
		if(toterr/255 > 2 || toterr/255 < -2)
			fail("reference trial %d: area differs by %d pixels", trial, (int)(toterr/255));
	}
	print("reference: largest pixel difference %d/255\n", (int)maxerr);
	freememimage(m);
}

/* Drawing in pieces (as layers are, and clipped windows) gives the same pixels. */
static void
testtiles(void)
{
	Memimage *whole, *tiled;
	Aapath p;
	Aapoly poly;
	int x, y, tx, ty;

	aapathinit(&p);
	aamoveto(&p, Pt(F(3.3), F(4.1)));
	aacurveto(&p, Pt(F(60), F(-10)), Pt(F(-5), F(70)), Pt(F(57.7), F(55.2)));
	aalineto(&p, Pt(F(20), F(50)));
	aaquadto(&p, Pt(F(40), F(20)), Pt(F(3.3), F(4.1)));
	aapolyinit(&poly);
	aastroke(&poly, &p, F(3.5), Capround, Capround, Joinround, F(4));
	aafill(&poly, &p);

	whole = canvas(64, 64);
	_memaadraw(whole, &poly, Pt(0, 0), ~0, memwhite, Pt(0, 0), whole->r, SoverD);
	tiled = canvas(64, 64);
	for(ty = 0; ty < 64; ty += 13)
		for(tx = 0; tx < 64; tx += 7)
			_memaadraw(tiled, &poly, Pt(0, 0), ~0, memwhite, Pt(0, 0), Rect(tx, ty, tx+7, ty+13), SoverD);
	for(y = 0; y < 64; y++)
		for(x = 0; x < 64; x++)
			if(px(whole, x, y) != px(tiled, x, y))
				fail("tiles: pixel %d,%d is %d whole, %d tiled", x, y, px(whole, x, y), px(tiled, x, y));
	if(total(whole) == 0)
		fail("tiles: nothing drawn");

	/* offset: the same polygon moved by a whole pixel is the same pixels moved */
	memfillcolor(tiled, DBlack);
	_memaadraw(tiled, &poly, Pt(3, -2), ~0, memwhite, Pt(0, 0), tiled->r, SoverD);
	for(y = 2; y < 62; y++)
		for(x = 0; x < 61; x++)
			if(px(whole, x, y) != px(tiled, x+3, y-2))
				fail("offset: pixel %d,%d", x, y);
	aapolyfree(&poly);
	aapathfree(&p);
	freememimage(whole);
	freememimage(tiled);
}

/* The wire format, and that it refuses what is not a path. */
static void
testdecode(void)
{
	Aapath p;
	uchar ok[] = {'M', 20, 40, 'L', 0x80|0x10, 0x04, 0, 'Z'};	/* M 10,20 L 10+..., Z */
	uchar bad1[] = {'M', 20};
	uchar bad2[] = {'X'};

	aapathinit(&p);
	if(aadecode(&p, ok, sizeof ok) < 0 || p.np != 2 || p.p[0].x != 10 || p.p[0].y != 20 || p.p[1].x != 10+264 || !p.closed[0])
		fail("decode: np %d p0 %P p1 %P", p.np, p.np > 0 ? p.p[0] : ZP, p.np > 1 ? p.p[1] : ZP);
	aapathfree(&p);
	aapathinit(&p);
	if(aadecode(&p, bad1, sizeof bad1) >= 0)
		fail("decode: truncated path accepted");
	aapathfree(&p);
	aapathinit(&p);
	if(aadecode(&p, bad2, sizeof bad2) >= 0)
		fail("decode: unknown verb accepted");
	aapathfree(&p);
}

/* libdraw's encoder (the client) against aadecode (the draw device) */
static void
testroundtrip(void)
{
	Path *w;
	Aapath p, q;
	Point pts[] = {{-300000, 7}, {1, -1}, {123456, 654321}, {0, 0}, {-5, 90000}};
	int i;

	w = allocpath();
	pathmove(w, pts[0]);
	pathline(w, pts[1]);
	pathquad(w, pts[2], pts[3]);
	pathcurve(w, pts[4], pts[0], pts[1]);
	pathclose(w);
	pathellipse(w, Pt(F(40), F(40)), F(10), F(5));
	aapathinit(&p);
	if(aadecode(&p, w->buf, w->n) < 0)
		fail("round trip: decode failed");
	aapathinit(&q);
	aamoveto(&q, pts[0]);
	aalineto(&q, pts[1]);
	aaquadto(&q, pts[2], pts[3]);
	aacurveto(&q, pts[4], pts[0], pts[1]);
	aaclosepath(&q);
	aaellipse(&q, Pt(F(40), F(40)), F(10), F(5));
	if(p.np != q.np || p.nsub != q.nsub)
		fail("round trip: %d points %d subpaths, want %d %d", p.np, p.nsub, q.np, q.nsub);
	else
		for(i = 0; i < p.np; i++)
			if(!eqpt(p.p[i], q.p[i])){
				fail("round trip: point %d is %P, want %P", i, p.p[i], q.p[i]);
				break;
			}
	aapathfree(&p);
	aapathfree(&q);
	freepath(w);
}

/*
 * The coverage fast path (coverdraw in draw.c) against the general
 * alphadraw: random masks and colours, opaque and translucent, onto
 * every 24- and 32-bit layout, compared byte for byte.
 */
static void
testfastpath(void)
{
	ulong chans[] = {XRGB32, ARGB32, RGBA32, ABGR32, XBGR32, RGB24, BGR24};
	char *names[] = {"XRGB32", "ARGB32", "RGBA32", "ABGR32", "XBGR32", "RGB24", "BGR24"};
	Memimage *a, *b, *mask, *src;
	Rectangle r;
	Point mp;
	int c, trial, i, n, srcalpha;
	ulong seed, col, al;
	uchar *pa, *pb;

	seed = 777;
	mask = allocmemimage(Rect(0, 0, 61, 37), GREY8);
	for(c = 0; c < nelem(chans); c++){
		a = allocmemimage(Rect(-5, -3, 56, 34), chans[c]);
		b = allocmemimage(a->r, chans[c]);
		for(trial = 0; trial < 40; trial++){
			n = Dy(a->r)*a->width*sizeof(ulong);
			pa = (uchar*)a->data->bdata;
			pb = (uchar*)b->data->bdata;
			for(i = 0; i < n; i++)
				pa[i] = pb[i] = RND();
			pa = byteaddr(mask, mask->r.min);
			for(i = 0; i < Dy(mask->r)*mask->width*sizeof(ulong); i++){
				switch(RND()%4){
				case 0:	pa[i] = 0; break;
				case 1:	pa[i] = 255; break;
				default: pa[i] = RND(); break;
				}
			}
			/* a premultiplied colour, sometimes opaque, with or without an alpha channel */
			srcalpha = trial%2;
			al = !srcalpha || trial%3 == 0 ? 255 : RND()&0xFF;
			col = ((RND()%(al+1)) << 24) | ((RND()%(al+1)) << 16) | ((RND()%(al+1)) << 8) | al;
			src = allocmemimage(Rect(0, 0, 1, 1), srcalpha ? RGBA32 : RGB24);
			src->flags |= Frepl;
			src->clipr = Rect(-0x3FFFFFF, -0x3FFFFFF, 0x3FFFFFF, 0x3FFFFFF);
			memfillcolor(src, col);
			r = Rect(RND()%10 - 5, RND()%8 - 3, 20 + RND()%36, 12 + RND()%22);
			mp = Pt(RND()%5, RND()%5);
			memdrawfast = 1;
			memimagedraw(a, r, src, ZP, mask, mp, SoverD);
			memdrawfast = 0;
			memimagedraw(b, r, src, ZP, mask, mp, SoverD);
			memdrawfast = 1;
			freememimage(src);
			pa = (uchar*)a->data->bdata;
			pb = (uchar*)b->data->bdata;
			for(i = 0; i < n; i++)
				if(pa[i] != pb[i]){
					fail("fast path: %s, trial %d (colour %.8lux%s): byte %d is %d, general path %d",
						names[c], trial, col, srcalpha ? "" : ", opaque source", i, pa[i], pb[i]);
					break;
				}
		}
		freememimage(a);
		freememimage(b);
	}
	freememimage(mask);
}

/*
 * The blending fast path (blenddraw) against alphadraw: random
 * premultiplied images with alpha, unmasked, onto every layout.
 */
static void
testblendpath(void)
{
	ulong dchans[] = {XRGB32, ARGB32, RGBA32, ABGR32, XBGR32, RGB24, BGR24};
	ulong schans[] = {RGBA32, ARGB32, ABGR32};
	Memimage *a, *b, *src;
	Rectangle r;
	Point sp;
	int c, sc, trial, i, n, x, y, al;
	ulong seed, v;
	uchar *pa, *pb;

	seed = 4242;
	for(sc = 0; sc < nelem(schans); sc++){
		src = allocmemimage(Rect(0, 0, 40, 30), schans[sc]);
		for(c = 0; c < nelem(dchans); c++){
			a = allocmemimage(Rect(-5, -3, 56, 34), dchans[c]);
			b = allocmemimage(a->r, dchans[c]);
			for(trial = 0; trial < 20; trial++){
				n = Dy(a->r)*a->width*sizeof(ulong);
				pa = (uchar*)a->data->bdata;
				pb = (uchar*)b->data->bdata;
				for(i = 0; i < n; i++)
					pa[i] = pb[i] = RND();
				/* premultiplied: no channel above alpha */
				for(y = 0; y < 30; y++)
					for(x = 0; x < 40; x++){
						switch(RND()%4){
						case 0:	al = 0; break;
						case 1:	al = 255; break;
						default: al = RND()&0xFF; break;
						}
						v = (RND()%(al+1))<<24 | (RND()%(al+1))<<16 | (RND()%(al+1))<<8 | al;
						v = rgbatocolour(src, v);
						pa = byteaddr(src, Pt(x, y));
						pa[0] = v; pa[1] = v>>8; pa[2] = v>>16; pa[3] = v>>24;
					}
				r = Rect(RND()%10 - 5, RND()%8 - 3, 10 + RND()%30, 8 + RND()%22);
				sp = Pt(RND()%5, RND()%5);
				memdrawfast = 1;
				memimagedraw(a, r, src, sp, memopaque, ZP, SoverD);
				memdrawfast = 0;
				memimagedraw(b, r, src, sp, memopaque, ZP, SoverD);
				memdrawfast = 1;
				pa = (uchar*)a->data->bdata;
				pb = (uchar*)b->data->bdata;
				for(i = 0; i < n; i++)
					if(pa[i] != pb[i]){
						fail("blend path: source %d onto layout %d, trial %d: byte %d is %d, general path %d",
							sc, c, trial, i, pa[i], pb[i]);
						break;
					}
			}
			freememimage(a);
			freememimage(b);
		}
		freememimage(src);
	}
}

/* an rgba value (r<<24 | g<<16 | b<<8 | a) as a pixel of m's channels */
static ulong
rgbatocolour(Memimage *m, ulong rgba)
{
	ulong v;

	v = ((rgba>>24)&0xFF) << m->shift[CRed];
	v |= ((rgba>>16)&0xFF) << m->shift[CGreen];
	v |= ((rgba>>8)&0xFF) << m->shift[CBlue];
	v |= (rgba&0xFF) << m->shift[CAlpha];
	return v;
}

int
main(int argc, char **argv)
{
	USED(argc);
	USED(argv);
	memimageinit();
	fmtinstall('P', Pfmt);
	testrect();
	testcircle();
	testrules();
	teststrokes();
	testreference();
	testtiles();
	testdecode();
	testroundtrip();
	testfastpath();
	testblendpath();
	if(failed){
		print("aatest: %d failed\n", failed);
		return 1;
	}
	print("aatest: ok\n");
	return 0;
}
