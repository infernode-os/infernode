#include "lib9.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "bayerif.h"
#include "bayermod.h"

/*
 * $Bayer: a raw frame to I420 by merging whole Bayer cells. No
 * interpolation: each output pixel has its own red, green and blue
 * from the cells it covers, which is what makes it cheap enough for
 * video, and quieter than one sample of each.
 *
 * Full-range coefficients, the inverse of libinterp/i420.c's.
 */

enum
{
	B	= 16,
	Half	= 1<<(B-1),
};

/* chroma can reach 256 for a primary at full strength: in a byte that is 0 */
static uchar
clampc(int v)
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

void
bayermodinit(void)
{
	builtinmod("$Bayer", Bayermodtab, Bayermodlen);
}

void
Bayer_merge(void *fp)
{
	F_Bayer_merge *f;
	ushort *raw, *c;
	uchar *lr, *lg, *lb, *y, *cb, *cr;
	WORD *mean;
	int rw, rh, s, cells, n, w, h, x, y0, cx, cy, ro, bo, g1, g2, nl;
	int r, g, b, pr, pg, pb, sr[2], sg[2], sb[2];
	uvlong tr, tg, tb;

	f = fp;
	if(f->raw == H || f->lr == H || f->lg == H || f->lb == H
	|| f->y == H || f->cb == H || f->cr == H || f->mean == H)
		error(exNilref);
	rw = f->rw;
	rh = f->rh;
	s = f->scale;
	if(rw <= 0 || rh <= 0 || s < 2 || (s&1) || f->red < 0 || f->red > 3)
		error(exBounds);
	w = rw/s;
	h = rh/s;
	if((w|h)&1 || w == 0 || h == 0)
		error(exBounds);
	nl = f->lr->len;
	if(f->lg->len != nl || f->lb->len != nl || nl == 0)
		error(exBounds);
	if(f->raw->len < (vlong)rw*rh*2 || f->y->len < w*h || f->cb->len < (w/2)*(h/2)
	|| f->cr->len < (w/2)*(h/2) || f->mean->len < 3)
		error(exBounds);
	raw = (ushort*)f->raw->data;
	lr = f->lr->data;
	lg = f->lg->data;
	lb = f->lb->data;
	y = f->y->data;
	cb = f->cb->data;
	cr = f->cr->data;

	/* the cell, as offsets: red and blue are opposite corners */
	ro = (f->red>>1)*rw + (f->red&1);
	bo = ((f->red^3)>>1)*rw + ((f->red^3)&1);
	g1 = ((f->red^1)>>1)*rw + ((f->red^1)&1);
	g2 = ((f->red^2)>>1)*rw + ((f->red^2)&1);
	cells = s/2;
	n = cells*cells;
	tr = tg = tb = 0;

	for(y0 = 0; y0 < h; y0++){
		sr[0] = sr[1] = sg[0] = sg[1] = sb[0] = sb[1] = 0;
		for(x = 0; x < w; x++){
			r = g = b = 0;
			for(cy = 0; cy < cells; cy++){
				c = raw + (y0*s + 2*cy)*rw + x*s;
				for(cx = 0; cx < cells; cx++){
					r += c[ro];
					b += c[bo];
					g += c[g1] + c[g2];
					c += 2;
				}
			}
			r /= n;
			g /= 2*n;
			b /= n;
			tr += r;
			tg += g;
			tb += b;
			pr = lr[r < nl? r: nl-1];
			pg = lg[g < nl? g: nl-1];
			pb = lb[b < nl? b: nl-1];
			*y++ = (19595*pr + 38470*pg + 7471*pb + Half) >> B;
			sr[x&1] = pr;
			sg[x&1] = pg;
			sb[x&1] = pb;
			if(x&1){
				/* two pixels' worth a row; the next row's are ignored */
				pr = (sr[0]+sr[1])/2;
				pg = (sg[0]+sg[1])/2;
				pb = (sb[0]+sb[1])/2;
				if((y0&1) == 0){
					*cb++ = clampc(128 + ((-11059*pr - 21709*pg + 32768*pb + Half) >> B));
					*cr++ = clampc(128 + ((32768*pr - 27439*pg - 5329*pb + Half) >> B));
				}
			}
		}
	}
	mean = (WORD*)f->mean->data;
	mean[0] = tr/((uvlong)w*h);
	mean[1] = tg/((uvlong)w*h);
	mean[2] = tb/((uvlong)w*h);
}
