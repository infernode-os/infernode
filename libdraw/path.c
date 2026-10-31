#include "lib9.h"
#include "draw.h"

/*
 * Anti-aliased paths: built here, encoded as the draw device takes
 * them (see draw(3)), and filled or stroked there.  Coordinates are
 * fixed point, Pathunit to a pixel.
 *
 * A verb is a byte and its points; each coordinate is the difference
 * from the last one (x from x, y from y), as a zigzag varint: seven
 * bits a byte, low first, the top bit set on all but the last.  An
 * ellipse's semi-axes are plain values, not differences.
 */

enum
{
	Maxverb	= 1+4*2*5,	/* the longest verb: C, three points of 5-byte coordinates */
	Pathhdr	= 1+4+4+2*4+4*4+2,	/* the longer of 'G' and 'g', before the path */
	Pathchunk	= Displaybufsize - Pathhdr,	/* path bytes one message can carry */
};

static uchar*
putcoord(uchar *a, int v)
{
	uint u;

	u = ((uint)v << 1) ^ (uint)(v >> 31);
	while(u >= 0x80){
		*a++ = u | 0x80;
		u >>= 7;
	}
	*a++ = u;
	return a;
}

/*
 * Encode verb and its np points at a, which has room for Maxverb
 * bytes; last is the previous point, updated.  The bytes written.
 */
int
_pathverb(uchar *a, Point *last, int verb, Point *p, int np)
{
	uchar *s;
	int i;

	s = a;
	*a++ = verb;
	if(verb == 'E'){	/* centre, then semi-axes as they are */
		a = putcoord(a, p[0].x - last->x);
		a = putcoord(a, p[0].y - last->y);
		*last = p[0];
		a = putcoord(a, p[1].x);
		a = putcoord(a, p[1].y);
		return a - s;
	}
	for(i = 0; i < np; i++){
		a = putcoord(a, p[i].x - last->x);
		a = putcoord(a, p[i].y - last->y);
		*last = p[i];
	}
	return a - s;
}

Path*
allocpath(void)
{
	return mallocz(sizeof(Path), 1);
}

void
freepath(Path *p)
{
	if(p == nil)
		return;
	free(p->buf);
	free(p);
}

static void
verb(Path *p, int v, Point *q, int nq)
{
	uchar *b;
	int n;

	if(p->err)
		return;
	if(p->n + Maxverb > p->nalloc){
		n = 2*p->nalloc + Maxverb;
		b = realloc(p->buf, n);
		if(b == nil){
			p->err = 1;
			return;
		}
		p->buf = b;
		p->nalloc = n;
	}
	p->n += _pathverb(p->buf + p->n, &p->last, v, q, nq);
}

void
pathmove(Path *p, Point a)
{
	verb(p, 'M', &a, 1);
}

void
pathline(Path *p, Point a)
{
	verb(p, 'L', &a, 1);
}

void
pathquad(Path *p, Point c, Point a)
{
	Point q[2];

	q[0] = c;
	q[1] = a;
	verb(p, 'Q', q, 2);
}

void
pathcurve(Path *p, Point c1, Point c2, Point a)
{
	Point q[3];

	q[0] = c1;
	q[1] = c2;
	q[2] = a;
	verb(p, 'C', q, 3);
}

/* a closed subpath round the ellipse: centre c, semi-axes a and b */
void
pathellipse(Path *p, Point c, int a, int b)
{
	Point q[2];

	q[0] = c;
	q[1] = Pt(a, b);
	verb(p, 'E', q, 2);
}

void
pathclose(Path *p)
{
	verb(p, 'Z', nil, 0);
}

/*
 * Send a path's bytes as the start of a 'G' or 'g' message with nf
 * fields f after its images and source point; what one message cannot
 * carry goes ahead in 'U' messages.
 */
static void
sendpath(Image *dst, int c, uchar *path, int n, int *f, int nf, Image *src, Point sp, Drawop op)
{
	uchar *a;
	int i, hdr;

	_setdrawop(dst->display, op);
	while(n > Pathchunk){
		a = bufimage(dst->display, 1+2+Pathchunk);
		if(a == nil){
			_drawprint(2, "image path: %r\n");
			return;
		}
		a[0] = 'U';
		BPSHORT(a+1, Pathchunk);
		memmove(a+3, path, Pathchunk);
		path += Pathchunk;
		n -= Pathchunk;
	}
	hdr = 1+4+4+2*4+4*nf+2;
	a = bufimage(dst->display, hdr+n);
	if(a == nil){
		_drawprint(2, "image path: %r\n");
		return;
	}
	a[0] = c;
	BPLONG(a+1, dst->id);
	BPLONG(a+5, src->id);
	BPLONG(a+9, sp.x);
	BPLONG(a+13, sp.y);
	for(i = 0; i < nf; i++)
		BPLONG(a+17+4*i, f[i]);
	BPSHORT(a+hdr-2, n);
	memmove(a+hdr, path, n);
}

/* fill encoded path bytes with the rule wind (as fillpoly's) */
void
_fillpath(Image *dst, uchar *path, int n, int wind, Image *src, Point sp, Drawop op)
{
	sendpath(dst, 'G', path, n, &wind, 1, src, sp, op);
}

/* stroke encoded path bytes width wide, with miters up to miter widths (all fixed point) */
void
_strokepath(Image *dst, uchar *path, int n, int width, int cap, int join, int miter, Image *src, Point sp, Drawop op)
{
	int f[4];

	f[0] = width;
	f[1] = cap;
	f[2] = join;
	f[3] = miter;
	sendpath(dst, 'g', path, n, f, 4, src, sp, op);
}

void
fillpathop(Image *dst, Path *p, int wind, Image *src, Point sp, Drawop op)
{
	if(p->err || p->n == 0)
		return;
	_fillpath(dst, p->buf, p->n, wind, src, sp, op);
}

void
fillpath(Image *dst, Path *p, int wind, Image *src, Point sp)
{
	fillpathop(dst, p, wind, src, sp, SoverD);
}

void
strokepathop(Image *dst, Path *p, int width, int cap, int join, Image *src, Point sp, Drawop op)
{
	if(p->err || p->n == 0)
		return;
	_strokepath(dst, p->buf, p->n, width, cap, join, 4*Pathunit, src, sp, op);
}

void
strokepath(Image *dst, Path *p, int width, int cap, int join, Image *src, Point sp)
{
	strokepathop(dst, p, width, cap, join, src, sp, SoverD);
}
