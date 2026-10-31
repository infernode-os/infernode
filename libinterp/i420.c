#include "lib9.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "i420if.h"
#include "i420mod.h"

/*
 * $I420: YCbCr 4:2:0 frames to RGB24, the arithmetic of
 * appl/mpeg/remap24.b in C, so the pixels are the same whichever
 * converts them: 16-bit fixed point, JPEG (full range) coefficients.
 */

enum
{
	B	= 16,
	/* remap24.b's int(c * real (1<<B)): Limbo rounds to nearest */
	B0	= -22554,	/* -0.34414 */
	B1	= 116130,	/* 1.772 */
	R0	= 91881,	/* 1.402 */
	R1	= -46802,	/* -0.71414 */
};

void
i420modinit(void)
{
	builtinmod("$I420", I420modtab, I420modlen);
}

static uchar
clamp(int v)
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

void
I420_rgb24(void *fp)
{
	F_I420_rgb24 *f;
	uchar *y, *cb, *cr, *o;
	int w, h, w2, i, k, u, v, gb, bb, rr, yy;

	f = fp;
	w = f->w;
	h = f->h;
	if(f->y == H || f->cb == H || f->cr == H || f->out == H)
		error(exNilref);
	if(w <= 0 || h <= 0 || (w|h)&1)
		error(exBounds);
	w2 = w/2;
	if(f->y->len < w*h || f->cb->len < w2*(h/2) || f->cr->len < w2*(h/2) || f->out->len < 3*w*h)
		error(exBounds);
	o = f->out->data;
	for(i = 0; i < h; i++){
		y = f->y->data + i*w;
		cb = f->cb->data + (i/2)*w2;
		cr = f->cr->data + (i/2)*w2;
		for(k = 0; k < w2; k++){
			u = cb[k] - 128;
			v = cr[k] - 128;
			gb = B0*u + R1*v;
			bb = B1*u;
			rr = R0*v;
			yy = *y++ << B;
			o[0] = clamp((yy + bb) >> B);
			o[1] = clamp((yy + gb) >> B);
			o[2] = clamp((yy + rr) >> B);
			yy = *y++ << B;
			o[3] = clamp((yy + bb) >> B);
			o[4] = clamp((yy + gb) >> B);
			o[5] = clamp((yy + rr) >> B);
			o += 6;
		}
	}
}
