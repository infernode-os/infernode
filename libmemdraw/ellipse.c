#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "memlayer.h"

/*
 * ellipse(dst, c, a, b, t, src, sp)
 *   draws an ellipse centered at c with semiaxes a,b>=0
 *   and semithickness t>=0, or filled if t<0.  point sp
 *   in src maps to c in dst
 *
 *   an outline is the ring 1+2t pixels wide centred on the ellipse
 *   through the pixel centres, anti-aliased (aa.c).  a filled
 *   ellipse keeps hard edges, so filled shapes that share an edge
 *   meet without a seam: its pixels are those whose centres are
 *   inside, found scan line by scan line.
 */

typedef struct State	State;

/*
 * denote residual error by e(x,y) = b^2*x^2 + a^2*y^2 - a^2*b^2
 * e(x,y) = 0 on ellipse, e(x,y) < 0 inside, e(x,y) > 0 outside
 */

struct State {
	int	a;
	int	x;
	vlong	a2;	/* a^2 */
	vlong	b2;	/* b^2 */
	vlong	b2x;	/* b^2 * x */
	vlong	a2y;	/* a^2 * y */
	vlong	c1;
	vlong	c2;	/* test criteria */
	vlong	ee;	/* ee = e(x+1/2,y-1/2) - (a^2+b^2)/4 */
	vlong	dxe;
	vlong	dye;
	vlong	d2xe;
	vlong	d2ye;
};

static
State*
newstate(State *s, int a, int b)
{
	s->x = 0;
	s->a = a;
	s->a2 = (vlong)(a*a);
	s->b2 = (vlong)(b*b);
	s->b2x = (vlong)0;
	s->a2y = s->a2*(vlong)b;
	s->c1 = -((s->a2>>2) + (vlong)(a&1) + s->b2);
	s->c2 = -((s->b2>>2) + (vlong)(b&1));
	s->ee = -s->a2y;
	s->dxe = (vlong)0;
	s->dye = s->ee<<1;
	s->d2xe = s->b2<<1;
	s->d2ye = s->a2<<1;
	return s;
}

/*
 * return x coord of rightmost pixel on next scan line
 */
static
int
step(State *s)
{
	while(s->x < s->a) {
		if(s->ee+s->b2x <= s->c1 ||	/* e(x+1,y-1/2) <= 0 */
		   s->ee+s->a2y <= s->c2) {	/* e(x+1/2,y) <= 0 (rare) */
			s->dxe += s->d2xe;	  
			s->ee += s->dxe;	  
			s->b2x += s->b2;
			s->x++;	  
			continue;
		}
		s->dye += s->d2ye;	  
		s->ee += s->dye;	  
		s->a2y -= s->a2;
		if(s->ee-s->a2y <= s->c2) {	/* e(x+1/2,y-1) <= 0 */
			s->dxe += s->d2xe;	  
			s->ee += s->dxe;	  
			s->b2x += s->b2;
			return s->x++;
		}
		break;
	}
	return s->x;	  
}

static Point p00 = {0, 0};

static void
ring(Memimage *dst, Point c, int a, int b, int t, Memimage *src, Point sp, int op)
{
	Aapath p;
	Aapoly poly;
	Point cc;
	int w;

	w = (2*t+1)*Aaone/2;
	cc = Pt((c.x << Aashift) + Aaone/2, (c.y << Aashift) + Aaone/2);
	a <<= Aashift;
	b <<= Aashift;
	aapathinit(&p);
	aaellipse(&p, cc, a+w, b+w);
	if(a > w && b > w)
		aaellipse(&p, cc, a-w, b-w);
	aapolyinit(&poly);
	aafill(&poly, &p);
	memaadraw(dst, &poly, 1, src, subpt(sp, c), op);
	aapolyfree(&poly);
	aapathfree(&p);
}

/* a scan line of the filled ellipse, closed coordinates relative to its centre */
static void
erect(Memimage *dst, Point c, int x0, int x1, int y, Memimage *src, Point sp, int op)
{
	Rectangle r;

	r = Rect(c.x+x0, c.y+y, c.x+x1+1, c.y+y+1);
	memdraw(dst, r, src, addpt(sp, r.min), memopaque, p00, op);
}

void
memellipse(Memimage *dst, Point c, int a, int b, int t, Memimage *src, Point sp, int op)
{
	State out;
	int y, x;

	if(a < 0)
		a = -a;
	if(b < 0)
		b = -b;
	if(t >= 0){
		ring(dst, c, a, b, t, src, sp, op);
		return;
	}
	sp = subpt(sp, c);
	newstate(&out, a, y = b);
	for( ; y >= 0; y--){
		x = step(&out);
		erect(dst, c, -x, x, y, src, sp, op);
		if(y != 0)
			erect(dst, c, -x, x, -y, src, sp, op);
	}
}
