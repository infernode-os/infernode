#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"

/*
 * Lines.  A horizontal or vertical line with square ends is exactly a
 * rectangle of pixels, and is drawn as one.  Every other line is
 * anti-aliased: the stroke Draw describes (aadrawlines) filled with the
 * coverage of each pixel (aa.c).  The line's geometry does not depend
 * on clipr, so a line diced into pieces by the layer code, or clipped
 * by a window, has the same pixels wherever it is drawn.
 */
void
_memimageline(Memimage *dst, Point p0, Point p1, int end0, int end1, int radius, Memimage *src, Point sp, Rectangle clipr, int op)
{
	Rectangle oclipr, r;
	Point d, pts[2];
	Aapoly poly;

	if(radius < 0)
		return;
	if(rectclip(&clipr, dst->r) == 0)
		return;
	if(rectclip(&clipr, dst->clipr) == 0)
		return;
	d = subpt(sp, p0);
	if(rectclip(&clipr, rectsubpt(src->clipr, d)) == 0)
		return;
	if((src->flags&Frepl)==0 && rectclip(&clipr, rectsubpt(src->r, d))==0)
		return;

	if((p0.x == p1.x || p0.y == p1.y) && (end0&0x1F) == Endsquare && (end1&0x1F) == Endsquare){
		r = canonrect(Rpt(p0, p1));
		if(p0.x == p1.x){
			r.min.x -= radius;
			r.max.x += radius+1;
			r.max.y++;
		}else{
			r.min.y -= radius;
			r.max.y += radius+1;
			r.max.x++;
		}
		oclipr = dst->clipr;
		dst->clipr = clipr;
		sp = addpt(r.min, d);
		memimagedraw(dst, r, src, sp, memopaque, sp, op);
		dst->clipr = oclipr;
		return;
	}

	aapolyinit(&poly);
	pts[0] = p0;
	pts[1] = p1;
	aadrawlines(&poly, pts, 2, radius, end0, end1);
	_memaadraw(dst, &poly, Pt(0, 0), ~0, src, d, clipr, op);
	aapolyfree(&poly);
}

void
memimageline(Memimage *dst, Point p0, Point p1, int end0, int end1, int radius, Memimage *src, Point sp, int op)
{
	_memimageline(dst, p0, p1, end0, end1, radius, src, sp, dst->clipr, op);
}

/*
 * Simple-minded conservative code to compute bounding box of line.
 * Result is probably a little larger than it needs to be.
 */
static
void
addbbox(Rectangle *r, Point p)
{
	if(r->min.x > p.x)
		r->min.x = p.x;
	if(r->min.y > p.y)
		r->min.y = p.y;
	if(r->max.x < p.x+1)
		r->max.x = p.x+1;
	if(r->max.y < p.y+1)
		r->max.y = p.y+1;
}

int
memlineendsize(int end)
{
	int x3;

	if((end&0x3F) != Endarrow)
		return 0;
	if(end == Endarrow)
		x3 = Arrow3;
	else
		x3 = (end>>23) & 0x1FF;
	return x3;
}

Rectangle
memlinebbox(Point p0, Point p1, int end0, int end1, int radius)
{
	Rectangle r, r1;
	int extra;

	r.min.x = 10000000;
	r.min.y = 10000000;
	r.max.x = -10000000;
	r.max.y = -10000000;
	extra = memlineendsize(end0);
	if(extra < memlineendsize(end1))
		extra = memlineendsize(end1);
	/* +1: the anti-aliased edge of a diagonal reaches past the radius */
	r1 = insetrect(canonrect(Rpt(p0, p1)), -(radius+extra+1));
	addbbox(&r, r1.min);
	addbbox(&r, r1.max);
	return r;
}
