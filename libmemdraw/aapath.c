#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

/*
 * Paths for anti-aliased geometry: building them, flattening their
 * curves, reading them off the wire, and turning them into polygons to
 * fill (aafill) or outlines of their strokes (aastroke).  See aa.c for
 * the rasteriser, and draw(3) for the wire format.
 *
 * Everything is fixed point (Aaone to a pixel) and integer, so the
 * same path gives the same pixels on every machine.
 */

enum
{
	Tol	= Aaone/64,	/* how far a flattened curve may stray */
	Maxseg	= 1024,		/* segments one curve may flatten to */
	Maxpts	= 1<<22,	/* points in one path: 16 million pixels of outline */
	Ushift	= 16,		/* unit vectors are scaled by 1<<Ushift */
	U	= 1<<Ushift,
	Rshift	= 30,		/* rotations are scaled by 1<<Rshift */
};

/* cos and sin of 2π/8, 2π/16, ... 2π/65536, scaled by 1<<Rshift */
static vlong rotstep[][2] = {
	{759250125, 759250125},
	{992008094, 410903207},
	{1053110176, 209476638},
	{1068571464, 105245103},
	{1072448455, 52686014},
	{1073418433, 26350943},
	{1073660973, 13176464},
	{1073721611, 6588356},
	{1073736771, 3294193},
	{1073740561, 1647099},
	{1073741508, 823550},
	{1073741745, 411775},
	{1073741804, 205887},
	{1073741819, 102944},
};

static uvlong
isqrt(uvlong v)
{
	uvlong r, b;

	r = 0;
	b = (uvlong)1 << 62;
	while(b > v)
		b >>= 2;
	while(b != 0){
		if(v >= r + b){
			v -= r + b;
			r = (r >> 1) + b;
		}else
			r >>= 1;
		b >>= 2;
	}
	return r;
}

/* a/b rounded to nearest, b > 0 */
static vlong
rdiv(vlong a, vlong b)
{
	if(a >= 0)
		return (a + b/2) / b;
	return -((-a + b/2) / b);
}

static vlong
vlen(vlong x, vlong y)
{
	return isqrt(x*x + y*y);
}

/*
 * The number of steps round a circle of radius r (fixed point) for
 * chords to stray no more than Tol from it: N ≥ π√(r/2Tol), a power
 * of two, returned as its index in rotstep (N = 8<<index).
 */
/*
 * The polygon of N steps round a circle, its radius scaled by these
 * (1<<Rshift is 1), has the circle's area: √(2π/(N sin(2π/N))).  So a
 * flattened ellipse is not smaller than the ellipse, only less round.
 */
static vlong areascale[] = {
	1131624417,
	1087702139,
	1077201507,
	1074604867,
	1073957468,
	1073795728,
	1073755299,
	1073745193,
	1073742666,
	1073742035,
	1073741877,
	1073741837,
	1073741827,
	1073741825,
};

static int
circlesteps(vlong r)
{
	vlong need;
	int k;

	need = 4*isqrt(r/(2*Tol) + 1);	/* π√x < 4√x */
	for(k = 0; k < nelem(rotstep)-1 && (8<<k) < need; k++)
		;
	return k;
}

void
aapathinit(Aapath *p)
{
	memset(p, 0, sizeof *p);
}

void
aapathfree(Aapath *p)
{
	free(p->p);
	free(p->sub);
	free(p->closed);
	aapathinit(p);
}

static int
okpt(Point p)
{
	return p.x > -Aamaxcoord && p.x < Aamaxcoord && p.y > -Aamaxcoord && p.y < Aamaxcoord;
}

static void
pathpt(Aapath *p, Point q)
{
	Point *np;
	int n;

	if(p->err)
		return;
	if(!okpt(q) || p->np >= Maxpts){
		p->err = 1;
		return;
	}
	if(p->np == p->nalloc){
		n = p->nalloc*2;
		if(n == 0)
			n = 64;
		np = realloc(p->p, n*sizeof(Point));
		if(np == nil){
			p->err = 1;
			return;
		}
		p->p = np;
		p->nalloc = n;
	}
	p->p[p->np++] = q;
}

static int
npts(Aapath *p, int s)
{
	if(s+1 < p->nsub)
		return p->sub[s+1] - p->sub[s];
	return p->np - p->sub[s];
}

/* the current point; a path with no subpath starts at the origin */
static Point
curpt(Aapath *p)
{
	int s;

	if(p->nsub == 0 || p->np == 0)
		return Pt(0, 0);
	s = p->nsub-1;
	if(p->closed[s])
		return p->p[p->sub[s]];
	return p->p[p->np-1];
}

void
aamoveto(Aapath *p, Point q)
{
	int *ns, n;
	uchar *nc;

	if(p->err)
		return;
	/* a subpath that is only a move draws nothing: reuse it */
	if(p->nsub > 0 && !p->closed[p->nsub-1] && npts(p, p->nsub-1) == 1){
		p->p[p->np-1] = q;
		if(!okpt(q))
			p->err = 1;
		return;
	}
	if(p->nsub == p->nsuballoc){
		n = p->nsuballoc*2;
		if(n == 0)
			n = 8;
		ns = realloc(p->sub, n*sizeof(int));
		if(ns != nil)
			p->sub = ns;
		nc = realloc(p->closed, n);
		if(nc != nil)
			p->closed = nc;
		if(ns == nil || nc == nil){
			p->err = 1;
			return;
		}
		p->nsuballoc = n;
	}
	p->sub[p->nsub] = p->np;
	p->closed[p->nsub] = 0;
	p->nsub++;
	pathpt(p, q);
}

/* after a close, drawing goes on from the closed subpath's start */
static void
continuing(Aapath *p)
{
	if(p->nsub == 0 || p->closed[p->nsub-1])
		aamoveto(p, curpt(p));
}

void
aalineto(Aapath *p, Point q)
{
	continuing(p);
	pathpt(p, q);
}

void
aaclosepath(Aapath *p)
{
	if(p->nsub > 0)
		p->closed[p->nsub-1] = 1;
}

void
aaquadto(Aapath *p, Point c, Point e)
{
	Point s;
	vlong n, i, j, nn, L;

	continuing(p);
	s = curpt(p);
	L = vlen(s.x - 2*(vlong)c.x + e.x, s.y - 2*(vlong)c.y + e.y);
	n = isqrt(L/(4*Tol)) + 1;	/* error ≤ L/4n² */
	if(n > Maxseg)
		n = Maxseg;
	nn = n*n;
	for(i = 1; i < n; i++){
		j = n - i;
		pathpt(p, Pt(rdiv(j*j*s.x + 2*j*i*c.x + i*i*e.x, nn),
			rdiv(j*j*s.y + 2*j*i*c.y + i*i*e.y, nn)));
	}
	pathpt(p, e);
}

void
aacurveto(Aapath *p, Point c1, Point c2, Point e)
{
	Point s;
	vlong n, i, j, n3, L, L2;

	continuing(p);
	s = curpt(p);
	L = vlen(s.x - 2*(vlong)c1.x + c2.x, s.y - 2*(vlong)c1.y + c2.y);
	L2 = vlen(c1.x - 2*(vlong)c2.x + e.x, c1.y - 2*(vlong)c2.y + e.y);
	if(L2 > L)
		L = L2;
	n = isqrt(3*L/(4*Tol)) + 1;	/* error ≤ 3L/4n² */
	if(n > Maxseg)
		n = Maxseg;
	n3 = n*n*n;
	for(i = 1; i < n; i++){
		j = n - i;
		pathpt(p, Pt(rdiv(j*j*j*s.x + 3*j*j*i*c1.x + 3*j*i*i*c2.x + i*i*i*e.x, n3),
			rdiv(j*j*j*s.y + 3*j*j*i*c1.y + 3*j*i*i*c2.y + i*i*i*e.y, n3)));
	}
	pathpt(p, e);
}

/*
 * A closed subpath round the ellipse centred on c with semi-axes a
 * and b, clockwise on the screen from the rightmost point.  One
 * quadrant is computed and reflected, so the outline is symmetric.
 */
void
aaellipse(Aapath *p, Point c, int a, int b)
{
	vlong cs, sn, t, *q;
	int k, n, i, m;

	if(a <= 0 || b <= 0)
		return;
	k = circlesteps(a > b ? a : b);
	n = 8 << k;
	a = rdiv(a*areascale[k], (vlong)1<<Rshift);
	b = rdiv(b*areascale[k], (vlong)1<<Rshift);
	m = n/4;
	q = malloc(2*(m+1)*sizeof(vlong));
	if(q == nil){
		p->err = 1;
		return;
	}
	cs = (vlong)1 << Rshift;
	sn = 0;
	for(i = 0; i <= m; i++){
		q[2*i] = cs;
		q[2*i+1] = sn;
		t = rdiv(cs*rotstep[k][0] - sn*rotstep[k][1], (vlong)1<<Rshift);
		sn = rdiv(sn*rotstep[k][0] + cs*rotstep[k][1], (vlong)1<<Rshift);
		cs = t;
	}
	q[2*m] = 0;
	q[2*m+1] = (vlong)1 << Rshift;
#define	X(i)	((vlong)a*q[2*(i)] >> Rshift)
#define	Y(i)	((vlong)b*q[2*(i)+1] >> Rshift)
	aamoveto(p, Pt(c.x + a, c.y));
	for(i = 1; i <= m; i++)
		aalineto(p, Pt(c.x + X(i), c.y + Y(i)));
	for(i = m-1; i >= 0; i--)
		aalineto(p, Pt(c.x - X(i), c.y + Y(i)));
	for(i = 1; i <= m; i++)
		aalineto(p, Pt(c.x - X(i), c.y - Y(i)));
	for(i = m-1; i > 0; i--)
		aalineto(p, Pt(c.x + X(i), c.y - Y(i)));
#undef X
#undef Y
	aaclosepath(p);
	free(q);
}

/*
 * The wire format: a sequence of verbs, each a byte followed by its
 * points, each coordinate the difference from the previous one (x from
 * x, y from y, starting at 0), fixed point, as a zigzag varint: 7 bits
 * to a byte, low first, the top bit set on all but the last.
 *	M p		move
 *	L p		line
 *	Q c p		quadratic curve
 *	C c1 c2 p	cubic curve
 *	E c a b		ellipse: centre c, semi-axes a and b (plain values,
 *			not differences), a closed subpath
 *	Z		close
 */
static uchar*
getcoord(uchar *a, uchar *e, int *v)
{
	uvlong u;
	int s;

	u = 0;
	for(s = 0; s < 35; s += 7){
		if(a >= e)
			return nil;
		u |= (uvlong)(*a & 0x7F) << s;
		if((*a++ & 0x80) == 0){
			*v += (int)((u >> 1) ^ -(vlong)(u & 1));
			return a;
		}
	}
	return nil;
}

int
aadecode(Aapath *p, uchar *a, int n)
{
	uchar *e;
	Point q[3];
	int i, np, verb;
	int x, y, ax, bx;

	e = a + n;
	x = y = 0;
	while(a < e){
		verb = *a++;
		switch(verb){
		case 'M':
		case 'L':
			np = 1;
			break;
		case 'Q':
			np = 2;
			break;
		case 'C':
			np = 3;
			break;
		case 'Z':
			np = 0;
			break;
		case 'E':
			if((a = getcoord(a, e, &x)) == nil || (a = getcoord(a, e, &y)) == nil)
				return -1;
			q[0] = Pt(x, y);
			ax = bx = 0;
			if((a = getcoord(a, e, &ax)) == nil || (a = getcoord(a, e, &bx)) == nil)
				return -1;
			if(!okpt(q[0]) || ax < 0 || bx < 0 || ax >= Aamaxcoord || bx >= Aamaxcoord)
				return -1;
			aaellipse(p, q[0], ax, bx);
			if(p->err)
				return -1;
			continue;
		default:
			return -1;
		}
		for(i = 0; i < np; i++){
			if((a = getcoord(a, e, &x)) == nil || (a = getcoord(a, e, &y)) == nil)
				return -1;
			q[i] = Pt(x, y);
			if(!okpt(q[i]))
				return -1;
		}
		switch(verb){
		case 'M':	aamoveto(p, q[0]); break;
		case 'L':	aalineto(p, q[0]); break;
		case 'Q':	aaquadto(p, q[0], q[1]); break;
		case 'C':	aacurveto(p, q[0], q[1], q[2]); break;
		case 'Z':	aaclosepath(p); break;
		}
		if(p->err)
			return -1;
	}
	return 0;
}

/* Filling: every subpath is closed with an edge back to its start. */
void
aafill(Aapoly *poly, Aapath *p)
{
	int s, i, n;
	Point *q;

	if(p->err){
		poly->err = 1;
		return;
	}
	for(s = 0; s < p->nsub; s++){
		q = p->p + p->sub[s];
		n = npts(p, s);
		if(n < 2)
			continue;
		for(i = 1; i < n; i++)
			aapolyedge(poly, q[i-1], q[i]);
		aapolyedge(poly, q[n-1], q[0]);
	}
}

/*
 * Stroking.  The outline of a stroke is built as one polygon per open
 * subpath (and two per closed one): along the left of the path, round
 * the far end, back along the right, round the near end.  Filled
 * non-zero, the loops an inner join makes lie inside the stroke.  A
 * stroke built instead as a union of overlapping pieces would count
 * twice the coverage where the pieces' edges share a pixel, and bead.
 */
typedef struct Stroke Stroke;
struct Stroke
{
	Aapoly	*poly;
	int	hw;		/* half the width */
	int	join;
	vlong	miter;		/* limit on miter length / width, fixed point */
	Point	first;		/* of the outline being built */
	Point	last;
	int	started;
};

typedef struct Vec Vec;
struct Vec
{
	vlong	x, y;	/* a unit vector, scaled by U */
};

static Vec
unit(Point a, Point b)
{
	Vec v;
	vlong dx, dy, l;

	dx = b.x - a.x;
	dy = b.y - a.y;
	l = vlen(dx, dy);
	v.x = rdiv(dx*U, l);
	v.y = rdiv(dy*U, l);
	return v;
}

/* the left normal: the side +n is on, walking along v */
static Vec
normal(Vec v)
{
	Vec n;

	n.x = -v.y;
	n.y = v.x;
	return n;
}

static Vec
neg(Vec v)
{
	v.x = -v.x;
	v.y = -v.y;
	return v;
}

static Point
off(Point p, Vec v, vlong d)
{
	return Pt(p.x + rdiv(v.x*d, U), p.y + rdiv(v.y*d, U));
}

static void
to(Stroke *s, Point p)
{
	if(!s->started){
		s->first = p;
		s->last = p;
		s->started = 1;
		return;
	}
	aapolyedge(s->poly, s->last, p);
	s->last = p;
}

static void
endoutline(Stroke *s)
{
	if(s->started)
		aapolyedge(s->poly, s->last, s->first);
	s->started = 0;
}

/*
 * An arc of radius hw round c, from direction a to direction b turning
 * anticlockwise on the page (the angle in x, y falling), at most half a
 * turn; the end b itself is not added.
 */
static void
arcto(Stroke *s, Point c, Vec a, Vec b)
{
	vlong vx, vy, bx, by, t, cd, r;
	int k;

	k = circlesteps(s->hw);
	if(k == nelem(rotstep)-1)
		k--;
	vx = a.x << (Rshift - Ushift);
	vy = a.y << (Rshift - Ushift);
	bx = b.x << (Rshift - Ushift);
	by = b.y << (Rshift - Ushift);
	r = (vlong)1 << Rshift;
	cd = rotstep[k+1][0];		/* cos of half a step */
	for(;;){
		/* rotate v by one step, clockwise on the page */
		t = rdiv(vx*rotstep[k][0] + vy*rotstep[k][1], r);
		vy = rdiv(vy*rotstep[k][0] - vx*rotstep[k][1], r);
		vx = t;
		/* stop within half a step of b, or past it */
		if(((vx*bx + vy*by) >> Rshift) >= cd || vx*by - vy*bx > 0)
			break;
		to(s, Pt(c.x + rdiv(vx*s->hw, r), c.y + rdiv(vy*s->hw, r)));
	}
}

/*
 * Where the stroke, walking along u0 (a segment l0 long), turns to u1
 * (one l1 long) at v: the left side of the stroke from the end of the
 * u0 edge to the start of the u1 edge.
 */
static void
joint(Stroke *s, Point v, Vec u0, Vec u1, vlong l0, vlong l1)
{
	Vec n0, n1, m;
	vlong cross, dot, nd, lim;
	Point a, b;

	n0 = normal(u0);
	n1 = normal(u1);
	a = off(v, n0, s->hw);
	b = off(v, n1, s->hw);
	cross = u0.x*u1.y - u0.y*u1.x;
	dot = u0.x*u1.x + u0.y*u1.y;
	if(cross == 0 && dot > 0){	/* straight on */
		to(s, a);
		return;
	}
	if(cross > 0){	/* turning left: the left side is inside the turn */
		/*
		 * The corner is where the two edges cross, the miter point
		 * on this side, hw·tan(θ/2) = hw·sinθ/(1+cosθ) back along
		 * each segment.  Where the segments are too short for that,
		 * the outline pivots on v instead: a loop inside the stroke,
		 * which costs coverage counted twice where it meets the edge.
		 */
		nd = n0.x*n1.x + n0.y*n1.y;
		if(nd > -(vlong)U*U && 2*rdiv(s->hw*cross, (vlong)U*U + nd) <= (l0 < l1 ? l0 : l1)){
			m.x = rdiv((n0.x + n1.x)*(vlong)U*U, (vlong)U*U + nd);
			m.y = rdiv((n0.y + n1.y)*(vlong)U*U, (vlong)U*U + nd);
			to(s, off(v, m, s->hw));
			return;
		}
		to(s, a);
		to(s, v);
		to(s, b);
		return;
	}
	/* the left side is outside the turn */
	to(s, a);
	switch(s->join){
	case Joinround:
		arcto(s, v, n0, n1);
		break;
	case Joinmiter:
		/*
		 * The miter point is v + hw(n0+n1)/(1+n0·n1), and the miter
		 * is 1/cos(θ/2) = √(2/(1+n0·n1)) times the width; past the
		 * limit it is bevelled.  In fixed point, with n0·n1 scaled by
		 * U², the test is 2·Aaone²·U²/(U²+n0·n1) ≤ limit².
		 */
		nd = n0.x*n1.x + n0.y*n1.y;
		if(nd > -(vlong)U*U){
			lim = s->miter;
			if(rdiv(2*(vlong)Aaone*Aaone*U*U, (vlong)U*U + nd) <= lim*lim){
				m.x = rdiv((n0.x + n1.x)*(vlong)U*U, (vlong)U*U + nd);
				m.y = rdiv((n0.y + n1.y)*(vlong)U*U, (vlong)U*U + nd);
				to(s, off(v, m, s->hw));
			}
		}
		break;
	case Joinbevel:
		break;
	}
	to(s, b);
}

/* the end of the stroke at p, walking out along u: from the left side to the right */
static void
cap(Stroke *s, Point p, Vec u, int kind)
{
	Vec n;

	n = normal(u);
	switch(kind){
	case Capround:
		arcto(s, p, n, u);
		to(s, off(p, u, s->hw));
		arcto(s, p, u, neg(n));
		break;
	case Capsquare:
		to(s, off(off(p, n, s->hw), u, s->hw));
		to(s, off(off(p, neg(n), s->hw), u, s->hw));
		break;
	}
	to(s, off(p, neg(n), s->hw));
}

/* a stroke of one point: a dot, if its caps have extent */
static void
dot(Stroke *s, Point p, int kind)
{
	Vec u;

	u.x = U;
	u.y = 0;
	switch(kind){
	case Capround:
		to(s, off(p, normal(neg(u)), s->hw));
		cap(s, p, neg(u), Capround);
		cap(s, p, u, Capround);
		endoutline(s);
		break;
	case Capsquare:	/* wound as every other outline: anticlockwise on the page */
		to(s, Pt(p.x - s->hw, p.y - s->hw));
		to(s, Pt(p.x - s->hw, p.y + s->hw));
		to(s, Pt(p.x + s->hw, p.y + s->hw));
		to(s, Pt(p.x + s->hw, p.y - s->hw));
		endoutline(s);
		break;
	}
}

/*
 * Stroke every subpath with a line width wide (fixed point), the start
 * of each open one ended as cap0 and its end as cap1, joined as join,
 * with miters no longer than miter (fixed point) widths.
 */
void
aastroke(Aapoly *poly, Aapath *p, int width, int cap0, int cap1, int join, int miter)
{
	Stroke s;
	Point *q, *pts;
	Vec *u;
	vlong *l;
	int sub, i, n, m;

	if(p->err){
		poly->err = 1;
		return;
	}
	if(width <= 0)
		return;
	memset(&s, 0, sizeof s);
	s.poly = poly;
	s.hw = width/2;
	if(s.hw == 0)
		s.hw = 1;
	s.join = join;
	s.miter = miter;
	if(s.miter < Aaone)
		s.miter = Aaone;
	if(s.miter > (vlong)1<<30)
		s.miter = (vlong)1<<30;
	pts = malloc((p->np+1)*sizeof(Point));
	u = malloc((p->np+1)*sizeof(Vec));
	l = malloc((p->np+1)*sizeof(vlong));
	if(pts == nil || u == nil || l == nil){
		poly->err = 1;
		goto Out;
	}
	for(sub = 0; sub < p->nsub; sub++){
		q = p->p + p->sub[sub];
		n = npts(p, sub);
		/* drop repeated points; a closed subpath's end is its start */
		m = 0;
		for(i = 0; i < n; i++)
			if(m == 0 || !eqpt(q[i], pts[m-1]))
				pts[m++] = q[i];
		if(p->closed[sub] && m > 1 && eqpt(pts[0], pts[m-1]))
			m--;
		if(m == 1){
			if(n > 1 || p->closed[sub])
				dot(&s, pts[0], cap0);
			continue;
		}
		for(i = 0; i+1 < m; i++){
			u[i] = unit(pts[i], pts[i+1]);
			l[i] = vlen(pts[i+1].x - pts[i].x, pts[i+1].y - pts[i].y);
		}
		if(p->closed[sub]){
			u[m-1] = unit(pts[m-1], pts[0]);
			l[m-1] = vlen(pts[0].x - pts[m-1].x, pts[0].y - pts[m-1].y);
			/* the left side, round and round */
			to(&s, off(pts[0], normal(u[0]), s.hw));
			for(i = 1; i < m; i++)
				joint(&s, pts[i], u[i-1], u[i], l[i-1], l[i]);
			joint(&s, pts[0], u[m-1], u[0], l[m-1], l[0]);
			endoutline(&s);
			/* the right side: the left of the path walked backwards */
			to(&s, off(pts[0], normal(neg(u[m-1])), s.hw));
			for(i = m-1; i > 0; i--)
				joint(&s, pts[i], neg(u[i]), neg(u[i-1]), l[i], l[i-1]);
			joint(&s, pts[0], neg(u[0]), neg(u[m-1]), l[0], l[m-1]);
			endoutline(&s);
			continue;
		}
		to(&s, off(pts[0], normal(u[0]), s.hw));
		for(i = 1; i+1 < m; i++)
			joint(&s, pts[i], u[i-1], u[i], l[i-1], l[i]);
		to(&s, off(pts[m-1], normal(u[m-2]), s.hw));
		cap(&s, pts[m-1], u[m-2], cap1);
		for(i = m-2; i > 0; i--)
			joint(&s, pts[i], neg(u[i]), neg(u[i-1]), l[i], l[i-1]);
		to(&s, off(pts[0], normal(neg(u[0])), s.hw));
		cap(&s, pts[0], neg(u[0]), cap0);
		endoutline(&s);
	}
    Out:
	free(pts);
	free(u);
	free(l);
}

/*
 * Draw's lines and polygons (line(2), poly): points on pixel centres,
 * 1+2*radius pixels wide.  Endsquare stops half a pixel past the point
 * (so a line touches both its points, and a thick one with square ends
 * is a rectangle), Enddisc is a disc on the point, Endarrow an
 * arrowhead whose tip is where a square end would stop.  Joins are
 * round, as the discs Draw's poly puts there; a one-pixel line joins
 * mitred, so a corner on pixel centres is a sharp pixel, not a blur.
 * The stroke is added to poly, to be filled non-zero.
 */
static Point
centre(Point p)
{
	return Pt((p.x << Aashift) + Aaone/2, (p.y << Aashift) + Aaone/2);
}

/* the arrowhead on the end at tip, pointing along u, as memimageline's */
static void
arrowhead(Aapoly *poly, Point tip, Vec u, int radius, int end)
{
	Vec n;
	Point q[5];
	vlong x1, x2, x3, w, area;
	int i;

	if(end == Endarrow){
		x1 = Arrow1;
		x2 = Arrow2;
		x3 = Arrow3;
	}else{
		x1 = (end>>5) & 0x1FF;	/* along the line from the end of the shaft to the tip */
		x2 = (end>>14) & 0x1FF;	/* along the line from the barbs to the tip */
		x3 = (end>>23) & 0x1FF;	/* across, from the edge of the shaft to a barb */
	}
	n = normal(u);
	w = (2*radius+1)*Aaone/2;
	q[0] = off(off(tip, u, -x1*Aaone), n, w);
	q[1] = off(off(tip, u, -x2*Aaone), n, w + x3*Aaone);
	q[2] = tip;
	q[3] = off(off(tip, u, -x2*Aaone), n, -(w + x3*Aaone));
	q[4] = off(off(tip, u, -x1*Aaone), n, -w);
	/* wound as the stroke outlines are, so the union fills */
	area = 0;
	for(i = 0; i < 5; i++)
		area += (vlong)q[i].x*q[(i+1)%5].y - (vlong)q[(i+1)%5].x*q[i].y;
	for(i = 0; i < 5; i++)
		if(area < 0)
			aapolyedge(poly, q[i], q[(i+1)%5]);
		else
			aapolyedge(poly, q[(i+1)%5], q[i]);
}

/*
 * One end of Draw's line: the point p, the stroke leaving it along u
 * (outwards).  Returns where the stroke itself should end, and the cap.
 */
static Point
drawend(Aapoly *poly, Point p, Vec u, int radius, int end, int *cap)
{
	Point tip;
	int x1;

	switch(end & 0x1F){
	case Enddisc:
		*cap = Capround;
		return p;
	case Endarrow:
		tip = off(p, u, Aaone/2);
		arrowhead(poly, tip, u, radius, end);
		x1 = end == Endarrow ? Arrow1 : (end>>5) & 0x1FF;
		*cap = Capbutt;
		return off(tip, u, -(vlong)x1*Aaone);
	default:	/* Endsquare */
		*cap = Capbutt;
		return off(p, u, Aaone/2);
	}
}

void
aadrawlines(Aapoly *poly, Point *pix, int n, int radius, int end0, int end1)
{
	Aapath p;
	Point *q, a, b;
	int i, m, cap0, cap1, join;

	if(n < 1)
		return;
	q = malloc(n*sizeof(Point));
	if(q == nil){
		poly->err = 1;
		return;
	}
	m = 0;
	for(i = 0; i < n; i++)
		if(m == 0 || !eqpt(pix[i], pix[i-1]))
			q[m++] = centre(pix[i]);
	aapathinit(&p);
	if(m == 1){
		aamoveto(&p, q[0]);
		aalineto(&p, q[0]);
		cap0 = (end0 & 0x1F) == Enddisc || (end1 & 0x1F) == Enddisc ? Capround : Capsquare;
		aastroke(poly, &p, (2*radius+1)*Aaone, cap0, cap0, Joinround, 0);
	}else{
		a = drawend(poly, q[0], unit(q[1], q[0]), radius, end0, &cap0);
		b = drawend(poly, q[m-1], unit(q[m-2], q[m-1]), radius, end1, &cap1);
		aamoveto(&p, a);
		for(i = 1; i < m-1; i++)
			aalineto(&p, q[i]);
		aalineto(&p, b);
		join = radius == 0 ? Joinmiter : Joinround;
		aastroke(poly, &p, (2*radius+1)*Aaone, cap0, cap1, join, 2*Aaone);
	}
	aapathfree(&p);
	free(q);
}

/*
 * The draw device's operations: a path from the wire, filled or
 * stroked, the source aligned so sp corresponds to the pixel holding
 * the path's first point.  The pixels changed are left in *r.
 */
static Point
firstpixel(Aapath *p)
{
	if(p->np == 0)
		return Pt(0, 0);
	return Pt(p->p[0].x >> Aashift, p->p[0].y >> Aashift);
}

char*
memfillpath(Memimage *dst, uchar *a, int n, int wind, Memimage *src, Point sp, int op, Rectangle *r)
{
	Aapath p;
	Aapoly poly;
	char *err;

	err = nil;
	aapathinit(&p);
	aapolyinit(&poly);
	*r = Rect(0, 0, 0, 0);
	if(aadecode(&p, a, n) < 0){
		err = "bad path";
		goto Out;
	}
	aafill(&poly, &p);
	if(poly.err){
		err = "path too complex";
		goto Out;
	}
	memaadraw(dst, &poly, wind, src, subpt(sp, firstpixel(&p)), op);
	*r = aapixels(&poly);
    Out:
	aapathfree(&p);
	aapolyfree(&poly);
	return err;
}

char*
memstrokepath(Memimage *dst, uchar *a, int n, int width, int cap, int join, int miter, Memimage *src, Point sp, int op, Rectangle *r)
{
	Aapath p;
	Aapoly poly;
	char *err;

	err = nil;
	aapathinit(&p);
	aapolyinit(&poly);
	*r = Rect(0, 0, 0, 0);
	if(width < 0 || cap < Capbutt || cap > Capsquare || join < Joinmiter || join > Joinbevel){
		err = "bad stroke";
		goto Out;
	}
	if(aadecode(&p, a, n) < 0){
		err = "bad path";
		goto Out;
	}
	aastroke(&poly, &p, width, cap, cap, join, miter);
	if(poly.err){
		err = "path too complex";
		goto Out;
	}
	memaadraw(dst, &poly, ~0, src, subpt(sp, firstpixel(&p)), op);
	*r = aapixels(&poly);
    Out:
	aapathfree(&p);
	aapolyfree(&poly);
	return err;
}
