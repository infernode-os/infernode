/*
 * Affine warps: the draw device's 'w' message, which 9front's libdraw
 * sends for affinewarp(2) (page, image/affinewarp, image/histogram).
 *
 * From 9front's sys/src/libmemdraw/warp.c (MIT licence, see NOTICE),
 * with these changes:
 *  - positions are accumulated and sampled in 64 bits, and warpok()
 *    bounds the matrix, so that no client's matrix or points overflow
 *    (signed overflow is undefined, and a sample's place came from it);
 *  - a pixel's address is taken in 64 bits (an image far down its
 *    coordinates passes an int of bytes, as memdraw_far_test has it);
 *  - the general pixel writer touches only the pixel's own bytes (it
 *    read and wrote four, past the end of an image for its last pixel);
 *  - the integer-upscale path is taken only when the matrix is one, at
 *    8 bits a pixel or more (the flag comes from the client, and below
 *    a byte its row copy would draw outside the rectangle);
 *  - the source's rectangle is given to hwdraw too, for the cursor;
 *  - 9front's filter kernels (memimagecorrelate) are left out: nothing
 *    in the draw protocol reaches them, and they need floating point,
 *    which a native kernel's drawing does without.
 */
#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

/* perfect approximation to NTSC = .299r+.587g+.114b when 0 <= r,g,b < 256 */
#define RGB2K(r,g,b)	((156763*(r)+307758*(g)+59769*(b))>>19)

/* alpha calculation from draw.c */
#define AMASK	0xFF00FF
#define CALC22(a1, vvuu1, a2, vvuu2, tmp) \
	(tmp=(a1)*(vvuu1)+(a2)*(vvuu2)+0x00800080, ((tmp+((tmp>>8)&AMASK))>>8)&AMASK)

#define CALC42(a1, rgba1, a2, rgba2, tmp1, tmp2) \
	(CALC22(a1, rgba1 & AMASK, a2, rgba2 & AMASK, tmp1) | \
	 (CALC22(a1, (rgba1>>8) & AMASK, a2, (rgba2>>8) & AMASK, tmp2)<<8))

/* 19.13 fixed point */
#define FMASK		((1<<13) - 1)
#define int2fix(n)	((vlong)(n)*(1<<13))	/* a multiply: n may be negative, and its shift is undefined */
#define fix2int(n)	((n)>>13)
#define fixmul(a,b)	((vlong)(a)*(vlong)(b) >> 13)
#define fixfrac(n)	((int)((n)&FMASK))
#define lerp(a,b,t)	((a) + ((((b) - (a))*(t))>>13))

/*
 * What warpok allows.  The linear part of the matrix is at most 2^24
 * (a factor of 2048 a pixel), a destination pixel at most 2^24 pixels
 * from the point the source's origin goes to.  The start is then under
 * 2^62 and a row or column of 2^33 pixels adds under 2^58: all of it
 * within a vlong.
 */
enum {
	Maxlinear	= 1<<24,
	Maxoffset	= 1<<24,
};

/* 9front's, which this tree's draw.h does not name */
#define BGR15	CHAN4(CIgnore, 1, CBlue, 5, CGreen, 5, CRed, 5)

/* a row's address in 64 bits */
#define ROW(a, y, bpl)	((a) + (vlong)(y)*(bpl))

typedef struct Sampler Sampler;
typedef struct Blitter Blitter;

struct Sampler
{
	Memimage	*i;
	uchar		*a;
	Rectangle	r;
	int		bpl;
	ulong		cmask;
	int		dx, dy;		/* bilinear's fractions */
	ulong		(*fn)(Sampler*, Point);
};

struct Blitter
{
	Memimage	*i;
	uchar		*a;
	int		bpl;
	ulong		cmask;
	Sampler		samp;		/* only used for blending */
	void		(*fn)(Blitter*, Point, ulong);
};

static void *getsampfn(ulong);
static void *getblitfn(ulong);

static void
initsampler(Sampler *s, Memimage *i)
{
	s->i = i;
	s->a = i->data->bdata + i->zero;
	s->bpl = sizeof(ulong)*i->width;
	s->cmask = (ulong)((1ULL << i->depth) - 1);
	s->fn = getsampfn(i->chan);
}

static void
initblitter(Blitter *b, Memimage *i)
{
	b->i = i;
	b->a = i->data->bdata + i->zero;
	b->bpl = sizeof(ulong)*i->width;
	b->cmask = (ulong)((1ULL << i->depth) - 1);
	b->fn = getblitfn(i->chan);
}

int
warpok(Warp *w)
{
	int i, j;

	for(i = 0; i < 2; i++)
		for(j = 0; j < 2; j++)
			if(w->m[i][j] > Maxlinear || w->m[i][j] < -Maxlinear)
				return 0;
	return 1;
}

static ulong
getpixel_k1(Sampler *s, Point pt)
{
	uchar *p;
	ulong off, npack, v;

	p = ROW(s->a, pt.y, s->bpl) + (pt.x >> 3);
	npack = 8-1;
	off = pt.x & npack;
	v = p[0] >> (npack-off) & 0x1;
	return v*0xFFFFFF00u | 0xFF;
}

static ulong
getpixel_k2(Sampler *s, Point pt)
{
	uchar *p, v;
	ulong off, npack;

	p = ROW(s->a, pt.y, s->bpl) + (pt.x*2 >> 3);
	npack = 8/2 - 1;
	off = pt.x & npack;
	v = p[0] >> 2*(npack-off) & 0x3;
	return (ulong)v*0x55555500u | 0xFF;
}

static ulong
getpixel_k4(Sampler *s, Point pt)
{
	uchar *p, v;
	ulong off, npack;

	p = ROW(s->a, pt.y, s->bpl) + (pt.x*4 >> 3);
	npack = 8/4 - 1;
	off = pt.x & npack;
	v = p[0] >> 4*(npack-off) & 0xF;
	return (ulong)v*0x11111100u | 0xFF;
}

static ulong
getpixel_k8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x;
	return (ulong)p[0]*0x01010100u | 0xFF;
}

static ulong
getpixel_m8(Sampler *s, Point pt)
{
	uchar *p, m;

	p = ROW(s->a, pt.y, s->bpl) + pt.x;
	m = p[0];
	p = s->i->cmap->cmap2rgb+3*m;
	return ((ulong)p[0]<<24)|(p[1]<<16)|(p[2]<<8)|0xFF;
}

static ulong
getpixel_x1r5g5b5(Sampler *s, Point pt)
{
	uchar *p, r, g, b;
	ulong val;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*2;
	val = p[0]|(p[1]<<8);
	b = val&0x1F; b = (b<<3)|(b>>2);
	val >>= 5;
	g = val&0x1F; g = (g<<3)|(g>>2);
	val >>= 5;
	r = val&0x1F; r = (r<<3)|(r>>2);
	return ((ulong)r<<24)|(g<<16)|(b<<8)|0xFF;
}

static ulong
getpixel_r5g6b5(Sampler *s, Point pt)
{
	uchar *p, r, g, b;
	ulong val;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*2;
	val = p[0]|(p[1]<<8);
	b = val&0x1F; b = (b<<3)|(b>>2);
	val >>= 5;
	g = val&0x3F; g = (g<<2)|(g>>4);
	val >>= 6;
	r = val&0x1F; r = (r<<3)|(r>>2);
	return ((ulong)r<<24)|(g<<16)|(b<<8)|0xFF;
}

static ulong
getpixel_r8g8b8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*3;
	return ((ulong)p[2]<<24)|(p[1]<<16)|(p[0]<<8)|0xFF;
}

static ulong
getpixel_r8g8b8a8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*4;
	return ((ulong)p[3]<<24)|(p[2]<<16)|(p[1]<<8)|p[0];
}

static ulong
getpixel_a8r8g8b8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*4;
	return ((ulong)p[2]<<24)|(p[1]<<16)|(p[0]<<8)|p[3];
}

static ulong
getpixel_x8r8g8b8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*4;
	return ((ulong)p[2]<<24)|(p[1]<<16)|(p[0]<<8)|0xFF;
}

static ulong
getpixel_x1b5g5r5(Sampler *s, Point pt)
{
	uchar *p, r, g, b;
	ulong val;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*2;
	val = p[0]|(p[1]<<8);
	r = val&0x1F; r = (r<<3)|(r>>2);
	val >>= 5;
	g = val&0x1F; g = (g<<3)|(g>>2);
	val >>= 5;
	b = val&0x1F; b = (b<<3)|(b>>2);
	return ((ulong)r<<24)|(g<<16)|(b<<8)|0xFF;
}

static ulong
getpixel_b8g8r8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*3;
	return ((ulong)p[0]<<24)|(p[1]<<16)|(p[2]<<8)|0xFF;
}

static ulong
getpixel_a8b8g8r8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*4;
	return ((ulong)p[0]<<24)|(p[1]<<16)|(p[2]<<8)|p[3];
}

static ulong
getpixel_x8b8g8r8(Sampler *s, Point pt)
{
	uchar *p;

	p = ROW(s->a, pt.y, s->bpl) + pt.x*4;
	return ((ulong)p[0]<<24)|(p[1]<<16)|(p[2]<<8)|0xFF;
}

static ulong
getpixel(Sampler *s, Point pt)
{
	uchar *p, r, g, b, a;
	ulong val, chan, ctype, ov, v;
	int nb, off, bpp, npack;

	val = 0;
	a = 0xFF;
	r = g = b = 0xAA;	/* garbage */
	p = ROW(s->a, pt.y, s->bpl) + (pt.x*s->i->depth >> 3);

	/* pixelbits() */
	switch(bpp = s->i->depth){
	case 1:
	case 2:
	case 4:
		npack = 8/bpp;
		off = pt.x%npack;
		if(off < 0)
			off += npack;
		val = p[0] >> bpp*(npack-1-off);
		val &= s->cmask;
		break;
	case 8:
		val = p[0];
		break;
	case 16:
		val = p[0]|(p[1]<<8);
		break;
	case 24:
		val = p[0]|(p[1]<<8)|(p[2]<<16);
		break;
	case 32:
		val = p[0]|(p[1]<<8)|(p[2]<<16)|((ulong)p[3]<<24);
		break;
	}

	while(bpp < 32){
		val |= val<<bpp;
		bpp *= 2;
	}

	/* imgtorgba() */
	for(chan = s->i->chan; chan; chan >>= 8){
		if((ctype = TYPE(chan)) == CIgnore){
			val >>= s->i->nbits[ctype];
			continue;
		}
		nb = s->i->nbits[ctype];
		ov = v = val & s->i->mask[ctype];
		val >>= nb;

		while(nb < 8){
			v |= v<<nb;
			nb *= 2;
		}
		v >>= nb-8;

		switch(ctype){
		case CRed:
			r = v;
			break;
		case CGreen:
			g = v;
			break;
		case CBlue:
			b = v;
			break;
		case CAlpha:
			a = v;
			break;
		case CGrey:
			r = g = b = v;
			break;
		case CMap:
			p = s->i->cmap->cmap2rgb+3*ov;
			r = p[0];
			g = p[1];
			b = p[2];
			break;
		}
	}
	return ((ulong)r<<24)|(g<<16)|(b<<8)|a;
}

static void
putpixel_k1(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, m;
	int off, npack, sh, mask;

	p = ROW(blt->a, dp.y, blt->bpl) + (dp.x >> 3);

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	m = RGB2K(r,g,b);
	m >>= 8-1;

	mask = 0x1;
	npack = 8-1;
	off = dp.x&npack;
	sh = npack-off;
	mask <<= sh;
	m <<= sh;
	p[0] = (p[0] ^ m) & mask ^ p[0];
}

static void
putpixel_k2(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, m;
	int off, npack, sh, mask;

	p = ROW(blt->a, dp.y, blt->bpl) + (dp.x*2 >> 3);

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	m = RGB2K(r,g,b);
	m >>= 8-2;

	mask = 0x3;
	npack = 8/2 - 1;
	off = dp.x&npack;
	sh = 2*(npack-off);
	mask <<= sh;
	m <<= sh;
	p[0] = (p[0] ^ m) & mask ^ p[0];
}

static void
putpixel_k4(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, m;
	int off, npack, sh, mask;

	p = ROW(blt->a, dp.y, blt->bpl) + (dp.x*4 >> 3);

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	m = RGB2K(r,g,b);
	m >>= 8-4;

	mask = 0xF;
	npack = 8/4 - 1;
	off = dp.x&npack;
	sh = 4*(npack-off);
	mask <<= sh;
	m <<= sh;
	p[0] = (p[0] ^ m) & mask ^ p[0];
}

static void
putpixel_k8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, m;

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	m = RGB2K(r,g,b);
	p = ROW(blt->a, dp.y, blt->bpl) + dp.x;
	p[0] = m;
}

static void
putpixel_m8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, m;

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	m = blt->i->cmap->rgb2cmap[(r>>4)*256+(g>>4)*16+(b>>4)];
	p = ROW(blt->a, dp.y, blt->bpl) + dp.x;
	p[0] = m;
}

static void
putpixel_x1r5g5b5(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b;
	ushort v;

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	v = r>>(8-5);
	v = (v<<5)|(g>>(8-5));
	v = (v<<5)|(b>>(8-5));
	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*2;
	p[0] = v;
	p[1] = v>>8;
}

static void
putpixel_r5g6b5(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b;
	ushort v;

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	v = r>>(8-5);
	v = (v<<6)|(g>>(8-6));
	v = (v<<5)|(b>>(8-5));
	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*2;
	p[0] = v;
	p[1] = v>>8;
}

static void
putpixel_r8g8b8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*3;
	p[0] = rgba>>8;
	p[1] = rgba>>16;
	p[2] = rgba>>24;
}

static void
putpixel_r8g8b8a8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*4;
	p[0] = rgba;
	p[1] = rgba>>8;
	p[2] = rgba>>16;
	p[3] = rgba>>24;
}

static void
putpixel_a8r8g8b8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*4;
	p[0] = rgba>>8;
	p[1] = rgba>>16;
	p[2] = rgba>>24;
	p[3] = rgba;
}

static void
putpixel_x8r8g8b8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*4;
	p[0] = rgba>>8;
	p[1] = rgba>>16;
	p[2] = rgba>>24;
}

static void
putpixel_x1b5g5r5(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b;
	ushort v;

	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	v = b>>(8-5);
	v = (v<<5)|(g>>(8-5));
	v = (v<<5)|(r>>(8-5));
	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*2;
	p[0] = v;
	p[1] = v>>8;
}

static void
putpixel_b8g8r8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*3;
	p[0] = rgba>>24;
	p[1] = rgba>>16;
	p[2] = rgba>>8;
}

static void
putpixel_a8b8g8r8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*4;
	p[0] = rgba>>24;
	p[1] = rgba>>16;
	p[2] = rgba>>8;
	p[3] = rgba;
}

static void
putpixel_x8b8g8r8(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p;

	p = ROW(blt->a, dp.y, blt->bpl) + dp.x*4;
	p[0] = rgba>>24;
	p[1] = rgba>>16;
	p[2] = rgba>>8;
}

static void
putpixel(Blitter *blt, Point dp, ulong rgba)
{
	uchar *p, r, g, b, a, m;
	ulong chan, ov, v, mask;
	int i, nbyte, off, npack, sh;

	p = ROW(blt->a, dp.y, blt->bpl) + (dp.x*blt->i->depth >> 3);
	nbyte = blt->i->depth < 8? 1: blt->i->depth/8;

	/* rgbatoimg() */
	v = 0;
	r = rgba>>24;
	g = rgba>>16;
	b = rgba>>8;
	a = rgba;
	for(chan=blt->i->chan; chan; chan>>=8){
		switch(TYPE(chan)){
		case CIgnore:
			continue;
		case CRed:
			v |= (r>>(8-blt->i->nbits[CRed])) << blt->i->shift[CRed];
			break;
		case CGreen:
			v |= (g>>(8-blt->i->nbits[CGreen])) << blt->i->shift[CGreen];
			break;
		case CBlue:
			v |= (b>>(8-blt->i->nbits[CBlue])) << blt->i->shift[CBlue];
			break;
		case CAlpha:
			v |= (a>>(8-blt->i->nbits[CAlpha])) << blt->i->shift[CAlpha];
			break;
		case CMap:
			m = blt->i->cmap->rgb2cmap[(r>>4)*256+(g>>4)*16+(b>>4)];
			v |= (m>>(8-blt->i->nbits[CMap])) << blt->i->shift[CMap];
			break;
		case CGrey:
			m = RGB2K(r,g,b);
			v |= (m>>(8-blt->i->nbits[CGrey])) << blt->i->shift[CGrey];
			break;
		}
	}

	/* blit op, on the pixel's own bytes alone */
	ov = 0;
	for(i = 0; i < nbyte; i++)
		ov |= (ulong)p[i] << 8*i;

	mask = blt->cmask;
	if(blt->i->depth < 8){
		npack = 8/blt->i->depth;
		off = dp.x%npack;
		if(off < 0)
			off += npack;
		sh = blt->i->depth*(npack-1-off);
		mask <<= sh;
		v <<= sh;
	}
	v = ((ov ^ v) & mask) ^ ov;	/* = (ov &~ mask) | (v & mask) */
	for(i = 0; i < nbyte; i++)
		p[i] = v >> 8*i;
}

static void *
getsampfn(ulong chan)
{
	switch(chan){
	case GREY1: return getpixel_k1;
	case GREY2: return getpixel_k2;
	case GREY4: return getpixel_k4;
	case GREY8: return getpixel_k8;
	case CMAP8: return getpixel_m8;
	case RGB15: return getpixel_x1r5g5b5;
	case RGB16: return getpixel_r5g6b5;
	case RGB24: return getpixel_r8g8b8;
	case RGBA32: return getpixel_r8g8b8a8;
	case ARGB32: return getpixel_a8r8g8b8;
	case XRGB32: return getpixel_x8r8g8b8;
	case BGR15: return getpixel_x1b5g5r5;
	case BGR24: return getpixel_b8g8r8;
	case ABGR32: return getpixel_a8b8g8r8;
	case XBGR32: return getpixel_x8b8g8r8;
	}
	return getpixel;
}

static void *
getblitfn(ulong chan)
{
	switch(chan){
	case GREY1: return putpixel_k1;
	case GREY2: return putpixel_k2;
	case GREY4: return putpixel_k4;
	case GREY8: return putpixel_k8;
	case CMAP8: return putpixel_m8;
	case RGB15: return putpixel_x1r5g5b5;
	case RGB16: return putpixel_r5g6b5;
	case RGB24: return putpixel_r8g8b8;
	case RGBA32: return putpixel_r8g8b8a8;
	case ARGB32: return putpixel_a8r8g8b8;
	case XRGB32: return putpixel_x8r8g8b8;
	case BGR15: return putpixel_x1b5g5r5;
	case BGR24: return putpixel_b8g8r8;
	case ABGR32: return putpixel_a8b8g8r8;
	case XBGR32: return putpixel_x8b8g8r8;
	}
	return putpixel;
}

static void
blendblit(Blitter *b, Point dp, ulong c)
{
	ulong sa, da;
	ulong dc, t, t1;

	sa = c & 0xFF;
	if(sa == 0)
		return;
	if(sa == 0xFF){
		b->fn(b, dp, c);
		return;
	}
	dc = b->samp.fn(&b->samp, dp);
	da = 255 - sa;
	dc = CALC42(sa, c, da, dc, t, t1);
	b->fn(b, dp, dc);
}

static vlong
replv(vlong min, vlong max, vlong x)
{
	vlong d;

	d = max - min;
	x = (x - min) % d;
	if(x < 0)
		x += d;
	return min + x;
}

/*
 * The source's pixel at (x, y), its rectangle's edge giving 0 (as
 * 9front's does) unless it is replicated.  x and y are a matrix's
 * work and may be anywhere; nothing outside the rectangle is read.
 */
static ulong
sample1(Sampler *s, vlong x, vlong y)
{
	Rectangle *r;

	r = &s->r;
	if(y >= r->min.y && y < r->max.y && x >= r->min.x && x < r->max.x)
		return s->fn(s, Pt((int)x, (int)y));
	if(s->i->flags & Frepl){
		x = replv(r->min.x, r->max.x, x);
		y = replv(r->min.y, r->max.y, y);
		return s->fn(s, Pt((int)x, (int)y));
	}
	return 0;
}

static ulong
bilinear(Sampler *s, vlong x, vlong y)
{
	ulong c00, c01, c10, c11;
	int c0[4], c1[4], i, sh;
	ulong v;

	c00 = sample1(s, x, y);
	c01 = sample1(s, x+1, y);
	c10 = sample1(s, x, y+1);
	c11 = sample1(s, x+1, y+1);

	v = 0;
	for(i = 0; i < 4; i++){
		sh = 24 - 8*i;
		c0[i] = lerp((int)(c00>>sh & 0xFF), (int)(c01>>sh & 0xFF), s->dx);
		c1[i] = lerp((int)(c10>>sh & 0xFF), (int)(c11>>sh & 0xFF), s->dx);
		v |= (ulong)(lerp(c0[i], c1[i], s->dy) & 0xFF) << sh;
	}
	return v;
}

/*
 * The source point for destination offset (ox, oy) from dp0, in 19.13:
 * the matrix applied to its pixel's centre.
 */
static void
xform(vlong *px, vlong *py, int ox, int oy, Warp *m)
{
	vlong x, y;

	x = int2fix(ox) + (1<<12);
	y = int2fix(oy) + (1<<12);
	*px = fixmul(x, m->m[0][0]) + fixmul(y, m->m[0][1]) + m->m[0][2];
	*py = fixmul(x, m->m[1][0]) + fixmul(y, m->m[1][1]) + m->m[1][2];
}

/* the matrix an integer upscale has, so intupscalewarp's way gives the same */
static int
isintupscale(Warp *w)
{
	return w->m[0][1] == 0 && w->m[1][0] == 0
		&& w->m[0][0] > 0 && w->m[0][0] <= (1<<13)
		&& w->m[1][1] > 0 && w->m[1][1] <= (1<<13);
}

/*
 * integer upscaling optimization
 */
static void
intupscalewarp(Blitter *blit, Point dp0, Rectangle r, Sampler *samp, Point sp0, Warp *m, int op)
{
	void (*blitfn)(Blitter*, Point, ulong);
	Point dp;
	vlong p2x, p2y, p2x0;
	ulong c, bpl;
	int i, dxdx, dydy;
	uchar *p;

	if(op == SoverD && (samp->i->flags & Falpha) != 0){
		initsampler(&blit->samp, blit->i);
		blitfn = blendblit;
	}else
		blitfn = blit->fn;
	bpl = Dx(r)*blit->i->depth >> 3;

	xform(&p2x, &p2y, r.min.x - dp0.x, r.min.y - dp0.y, m);
	p2x0 = p2x;

	dxdx = m->m[0][0];
	dydy = m->m[1][1];

	for(dp.y = r.min.y; dp.y < r.max.y; ){
		for(dp.x = r.min.x; dp.x < r.max.x; ){
			c = sample1(samp, sp0.x + fix2int(p2x), sp0.y + fix2int(p2y));
			for(i = fixfrac(p2x); i < (1<<13) && dp.x < r.max.x; i += dxdx){
				blitfn(blit, dp, c);
				dp.x++;
				p2x += dxdx;
			}
		}
		p = ROW(blit->a, dp.y, blit->bpl) + (r.min.x*blit->i->depth >> 3);
		dp.y++;
		i = fixfrac(p2y);
		p2y += dydy;
		i += dydy;
		for(; i < (1<<13) && dp.y < r.max.y; i += dydy){
			memmove(p+blit->bpl, p, bpl);
			p += blit->bpl;
			dp.y++;
			p2y += dydy;
		}
		p2x = p2x0;
	}
}

void
memaffinewarp(Memimage *d, Point dp0, Rectangle r, Memimage *s, Point sp0,
	Memimage *msk, Point mp, Warp *w, int smooth, int op)
{
	void (*blitfn)(Blitter*, Point, ulong);
	Memdrawparam par;
	Sampler samp;
	Blitter blit;
	Point dp;
	vlong p2x, p2y, p2x0, p2y0;
	Rectangle dr;
	ulong c;

	/* 9front's warp takes no mask: msk and mp are the protocol's */
	if(!warpok(w))
		return;
	/*
	 * A rectangle whose min is past its max is refused: clipping leaves
	 * it so, and the upscale path's row copy took its negative width
	 * for a size (9front checks it only on the way through layers).
	 */
	if(badrect(r))
		return;
	/*
	 * Where the destination may be drawn: its clip within its
	 * rectangle.  9front left dr the clip when the two did not meet
	 * (rectclip's result unread), and drew outside the image: the clip
	 * is the client's to set, so any client wrote past its pixels.
	 */
	dr = d->clipr;
	if(rectclip(&dr, d->r) == 0)
		return;
	if(rectclip(&r, dr) == 0)
		return;
	/*
	 * A clip is the client's too, and may be inverted: rectclip keeps
	 * an inverted rectangle inverted, and the row copy below took its
	 * negative width for a size.
	 */
	if(Dx(r) <= 0 || Dy(r) <= 0)
		return;
	if(r.min.x - (vlong)dp0.x > Maxoffset || r.min.x - (vlong)dp0.x < -Maxoffset
	|| r.min.y - (vlong)dp0.y > Maxoffset || r.min.y - (vlong)dp0.y < -Maxoffset
	|| Dx(r) > Maxoffset || Dy(r) > Maxoffset)
		return;

	samp.r = s->clipr;
	if(rectclip(&samp.r, s->r) == 0)
		return;
	/* the same for the source, whose replication divides by its size */
	if(Dx(samp.r) <= 0 || Dy(samp.r) <= 0)
		return;

	/* the software cursor off what is drawn and what is read */
	memset(&par, 0, sizeof par);
	par.dst = d;
	par.r = r;
	par.src = s;
	par.sr = samp.r;
	hwdraw(&par);

	initsampler(&samp, s);
	initblitter(&blit, d);

	if(!smooth && (w->flags & WFintupscale) != 0 && isintupscale(w) && d->depth >= 8){
		intupscalewarp(&blit, dp0, r, &samp, sp0, w, op);
		return;
	}
	if(op == SoverD && (s->flags & Falpha) != 0){
		initsampler(&blit.samp, d);
		blitfn = blendblit;
	}else
		blitfn = blit.fn;

	/*
	 * incremental affine warping technique from:
	 * 	"Fast Affine Transform for Real-Time Machine Vision Applications",
	 * 	Lee, S., Lee, GG., Jang, E.S., Kim, WY,
	 * 	Intelligent Computing.  ICIC 2006. LNCS, vol 4113.
	 */
	xform(&p2x0, &p2y0, r.min.x - dp0.x, r.min.y - dp0.y, w);
	p2x = p2x0;
	p2y = p2y0;
	for(dp.y = r.min.y; dp.y < r.max.y; dp.y++){
		for(dp.x = r.min.x; dp.x < r.max.x; dp.x++){
			if(smooth){
				samp.dx = fixfrac(p2x);
				samp.dy = fixfrac(p2y);
				c = bilinear(&samp, sp0.x + fix2int(p2x), sp0.y + fix2int(p2y));
			}else
				c = sample1(&samp, sp0.x + fix2int(p2x), sp0.y + fix2int(p2y));
			blitfn(&blit, dp, c);
			p2x += w->m[0][0];
			p2y += w->m[1][0];
		}
		p2x = p2x0 += w->m[0][1];
		p2y = p2y0 += w->m[1][1];
	}
}
