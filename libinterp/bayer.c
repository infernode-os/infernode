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
 *
 * The picture can be turned as it is written, for a camera mounted on
 * its side: each pixel goes where the turn puts it, a step of dx for
 * the next pixel along a row and dy for the next row, from base.
 */

enum
{
	B	= 16,
	Half	= 1<<(B-1),
};

/* chroma can reach 256 for a primary at full strength: in a byte that is 0 */
static void
turn(int rot, int w, int h, int *base, int *dx, int *dy)
{
	switch(rot){
	case 0:
		*base = 0; *dx = 1; *dy = w;
		break;
	case 1:	/* clockwise: the top left corner goes to the top right */
		*base = h-1; *dx = h; *dy = -1;
		break;
	case 2:
		*base = w*h-1; *dx = -1; *dy = -w;
		break;
	case 3:
		*base = (w-1)*h; *dx = -h; *dy = 1;
		break;
	}
}

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

/*
 * Lens shading. A lens gives its corners less light than its middle,
 * more so in some colours: each sample is multiplied up by a gain from
 * a coarse table made from a flat white field (camsrv's shade learn).
 * The gain is interpolated in 16.16 along a row from the two grid
 * columns either side, the rows themselves interpolated once a line.
 */
void
Bayer_shade(void *fp)
{
	F_Bayer_shade *f;
	ushort *raw, *p;
	WORD *t;
	int rw, rh, gw, gh, bl, mx, x, yy, q, j, gx, n;
	vlong gyf, fy, fx, a, b, g, v;
	int *row, *cgx, *cfx;

	f = fp;
	if(f->raw == H || f->table == H)
		error(exNilref);
	rw = f->rw;
	rh = f->rh;
	gw = f->gw;
	gh = f->gh;
	bl = f->black;
	mx = f->max;
	if(rw < 2 || rh < 2 || gw < 2 || gh < 2 || gw > 1024 || gh > 1024 || bl < 0 || mx <= bl
	|| f->raw->len < (vlong)rw*rh*2 || f->table->len < 4*gw*gh)
		error(exBounds);
	raw = (ushort*)f->raw->data;
	t = (WORD*)f->table->data;
	n = gw*gh;
	row = malloc(4*gw*sizeof(int));
	cgx = malloc(rw*sizeof(int));
	cfx = malloc(rw*sizeof(int));
	if(row == nil || cgx == nil || cfx == nil){
		free(row);
		free(cgx);
		free(cfx);
		error(exNomem);
	}
	/* each column's grid column and how far toward the next, once */
	for(x = 0; x < rw; x++){
		fx = ((vlong)x*(gw-1)<<16)/(rw-1);
		gx = fx>>16;
		if(gx >= gw-1)
			gx = gw-2;
		cgx[x] = gx;
		cfx[x] = fx - ((vlong)gx<<16);
	}
	for(yy = 0; yy < rh; yy++){
		/* this line's gains at each grid column, for both positions on it */
		gyf = ((vlong)yy*(gh-1)<<16)/(rh-1);
		j = gyf>>16;
		if(j >= gh-1)
			j = gh-2;
		fy = gyf - ((vlong)j<<16);
		for(q = (yy&1)*2; q < (yy&1)*2+2; q++)
			for(gx = 0; gx < gw; gx++){
				a = t[q*n + j*gw + gx];
				b = t[q*n + (j+1)*gw + gx];
				row[q*gw + gx] = a + (((b-a)*fy)>>16);
			}
		p = raw + yy*rw;
		for(x = 0; x < rw; x++, p++){
			q = (yy&1)*2 + (x&1);
			gx = cgx[x];
			fx = cfx[x];
			a = row[q*gw + gx];
			b = row[q*gw + gx + 1];
			g = a + (((b-a)*fx)>>16);
			v = *p - bl;
			if(v <= 0)
				continue;
			v = bl + ((v*g + 512)>>10);
			*p = v > mx? mx: v;
		}
	}
	free(row);
	free(cgx);
	free(cfx);
}

/*
 * NDVI over merge's blocks. The cell means are the raw channels' own,
 * black taken off; the ratio is what grey world would take away, which
 * is why it is not taken from the merged picture.
 */
void
Bayer_ndvi(void *fp)
{
	F_Bayer_ndvi *f;
	ushort *raw, *c;
	uchar *out, *o;
	int rw, rh, s, cells, n, w, h, x, y0, cx, cy, ro, bo, g1, g2, ob, odx, ody, i, k;
	vlong ch[3], nv, vv, sum, v;
	vlong hist[256], total, acc;
	WORD *stat;
	int pct[3], want[3];

	f = fp;
	if(f->raw == H || f->out == H || f->stat == H)
		error(exNilref);
	rw = f->rw;
	rh = f->rh;
	s = f->scale;
	if(rw <= 0 || rh <= 0 || s < 2 || (s&1) || f->red < 0 || f->red > 3
	|| f->rot < 0 || f->rot > 3 || f->nir < 0 || f->nir > 2 || f->vis < 0 || f->vis > 2
	|| f->nir == f->vis || f->black < 0 || f->floor < 0)
		error(exBounds);
	w = rw/s;
	h = rh/s;
	if(w == 0 || h == 0 || f->raw->len < (vlong)rw*rh*2 || f->out->len < w*h || f->stat->len < 4)
		error(exBounds);
	raw = (ushort*)f->raw->data;
	out = f->out->data;
	turn(f->rot, w, h, &ob, &odx, &ody);
	ro = (f->red>>1)*rw + (f->red&1);
	bo = ((f->red^3)>>1)*rw + ((f->red^3)&1);
	g1 = ((f->red^1)>>1)*rw + ((f->red^1)&1);
	g2 = ((f->red^2)>>1)*rw + ((f->red^2)&1);
	cells = s/2;
	n = cells*cells;
	memset(hist, 0, sizeof hist);
	for(y0 = 0; y0 < h; y0++){
		o = out + ob + y0*ody;
		for(x = 0; x < w; x++, o += odx){
			ch[0] = ch[1] = ch[2] = 0;
			for(cy = 0; cy < cells; cy++){
				c = raw + (y0*s + 2*cy)*rw + x*s;
				for(cx = 0; cx < cells; cx++){
					ch[0] += c[ro];
					ch[1] += c[g1] + c[g2];
					ch[2] += c[bo];
					c += 2;
				}
			}
			ch[0] = ch[0]/n - f->black;
			ch[1] = ch[1]/(2*n) - f->black;
			ch[2] = ch[2]/n - f->black;
			nv = ch[f->nir] > 0? ch[f->nir]: 0;
			vv = ch[f->vis] > 0? ch[f->vis]: 0;
			sum = nv + vv;
			if(sum < f->floor || sum == 0){
				*o = 0;
				continue;
			}
			/* 128 + round(127*(nv-vv)/sum), rounding half away from 0 */
			v = 127*(nv-vv)*2;
			v = v >= 0? (v + sum)/(2*sum): -((-v + sum)/(2*sum));
			*o = 128 + v;
			hist[128+v]++;
		}
	}
	stat = (WORD*)f->stat->data;
	total = 0;
	acc = 0;
	for(i = 1; i < 256; i++){
		total += hist[i];
		acc += hist[i]*(i-128);
	}
	if(total == 0){
		for(i = 0; i < 4; i++)
			stat[i] = 0;
		if(f->stat->len > 4)
			stat[4] = 0;
		return;
	}
	stat[0] = acc*1000/(127*total);
	want[0] = (total+9)/10;
	want[1] = (total+1)/2;
	want[2] = (9*total+9)/10;
	for(k = 0; k < 3; k++){
		acc = 0;
		pct[k] = 255;
		for(i = 1; i < 256; i++){
			acc += hist[i];
			if(acc >= want[k]){
				pct[k] = i;
				break;
			}
		}
		stat[k+1] = (pct[k]-128)*1000/127;
	}
	if(f->stat->len > 4)
		stat[4] = total;
}

void
Bayer_merge(void *fp)
{
	F_Bayer_merge *f;
	ushort *raw, *c;
	uchar *lr, *lg, *lb, *y, *cb, *cr, *yr, *cbr, *crr;
	int yb, ydx, ydy, cbase, cdx, cdy;
	WORD *mean;
	int rw, rh, s, cells, n, w, h, x, y0, cx, cy, ro, bo, g1, g2, nl;
	/*
	 * A cell's sums are 64 bits: at a scale of 258 the green one passes an
	 * int, went negative, and stayed negative when divided: an index
	 * before the table.
	 */
	uvlong r, g, b;
	int pr, pg, pb, sr[2], sg[2], sb[2], clip, top;
	uvlong tr, tg, tb, ur, ug, ub, un;

	f = fp;
	if(f->raw == H || f->lr == H || f->lg == H || f->lb == H
	|| f->y == H || f->cb == H || f->cr == H || f->mean == H)
		error(exNilref);
	rw = f->rw;
	rh = f->rh;
	s = f->scale;
	if(rw <= 0 || rh <= 0 || s < 2 || (s&1) || f->red < 0 || f->red > 3
	|| f->rot < 0 || f->rot > 3)
		error(exBounds);
	w = rw/s;
	h = rh/s;
	if((w|h)&1 || w == 0 || h == 0)
		error(exBounds);
	nl = f->lr->len;
	if(f->lg->len != nl || f->lb->len != nl || nl == 0)
		error(exBounds);
	if(f->raw->len < (vlong)rw*rh*2 || f->y->len < w*h || f->cb->len < (w/2)*(h/2)
	|| f->cr->len < (w/2)*(h/2) || f->mean->len < 3 || f->clip < 0)
		error(exBounds);
	raw = (ushort*)f->raw->data;
	lr = f->lr->data;
	lg = f->lg->data;
	lb = f->lb->data;
	y = f->y->data;
	cb = f->cb->data;
	cr = f->cr->data;
	turn(f->rot, w, h, &yb, &ydx, &ydy);
	turn(f->rot, w/2, h/2, &cbase, &cdx, &cdy);

	/* the cell, as offsets: red and blue are opposite corners */
	ro = (f->red>>1)*rw + (f->red&1);
	bo = ((f->red^3)>>1)*rw + ((f->red^3)&1);
	g1 = ((f->red^1)>>1)*rw + ((f->red^1)&1);
	g2 = ((f->red^2)>>1)*rw + ((f->red^2)&1);
	cells = s/2;
	n = cells*cells;
	tr = tg = tb = 0;
	ur = ug = ub = un = 0;
	clip = f->clip;

	for(y0 = 0; y0 < h; y0++){
		yr = y + yb + y0*ydy;
		cbr = cb + cbase + (y0>>1)*cdy;
		crr = cr + cbase + (y0>>1)*cdy;
		sr[0] = sr[1] = sg[0] = sg[1] = sb[0] = sb[1] = 0;
		for(x = 0; x < w; x++){
			r = g = b = 0;
			top = 0;
			for(cy = 0; cy < cells; cy++){
				c = raw + (y0*s + 2*cy)*rw + x*s;
				for(cx = 0; cx < cells; cx++){
					r += c[ro];
					b += c[bo];
					g += c[g1] + c[g2];
					/* the block's highest sample, for clip */
					if(c[ro] > top)
						top = c[ro];
					if(c[bo] > top)
						top = c[bo];
					if(c[g1] > top)
						top = c[g1];
					if(c[g2] > top)
						top = c[g2];
					c += 2;
				}
			}
			r /= n;
			g /= 2*n;
			b /= n;
			tr += r;
			tg += g;
			tb += b;
			if(clip == 0 || top < clip){
				ur += r;
				ug += g;
				ub += b;
				un++;
			}
			pr = lr[r < nl? r: nl-1];
			pg = lg[g < nl? g: nl-1];
			pb = lb[b < nl? b: nl-1];
			*yr = (19595*pr + 38470*pg + 7471*pb + Half) >> B;
			yr += ydx;
			sr[x&1] = pr;
			sg[x&1] = pg;
			sb[x&1] = pb;
			if(x&1){
				/* two pixels' worth a row; the next row's are ignored */
				pr = (sr[0]+sr[1])/2;
				pg = (sg[0]+sg[1])/2;
				pb = (sb[0]+sb[1])/2;
				if((y0&1) == 0){
					*cbr = clampc(128 + ((-11059*pr - 21709*pg + 32768*pb + Half) >> B));
					*crr = clampc(128 + ((32768*pr - 27439*pg - 5329*pb + Half) >> B));
					cbr += cdx;
					crr += cdx;
				}
			}
		}
	}
	mean = (WORD*)f->mean->data;
	mean[0] = tr/((uvlong)w*h);
	mean[1] = tg/((uvlong)w*h);
	mean[2] = tb/((uvlong)w*h);
	if(f->mean->len >= 6){
		mean[3] = un? ur/un: 0;
		mean[4] = un? ug/un: 0;
		mean[5] = un? ub/un: 0;
	}
}
