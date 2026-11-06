#include "lib9.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "tensorif.h"
#include "tensormod.h"

/*
 * $Tensor: a convolutional network's arithmetic, for vision(4); see
 * module/tensor.m. As $I420 and $Bayer are, it is functions over Limbo
 * arrays: it keeps nothing between calls, takes every decision (the
 * network, its activations, the picture's scale) as an argument, and
 * checks every size against the arrays it was given before it lets go
 * of the VM, so the arithmetic cannot reach outside them.
 *
 * The convolution is a matrix product, out = W x columns(in): the
 * columns are made 8 at a time straight into packed blocks (im2col
 * without the whole matrix), each block kept in the L2 cache while every
 * 8-row panel of weights, in L1, runs across it. On arm64 the 8x8 product
 * is NEON; elsewhere it is plain C. Measured on a Raspberry Pi 4 (#1086):
 * about 9 to 10 GFLOPS a core.
 */

#ifdef __aarch64__
#include <arm_neon.h>
#define NEON 1
#endif

enum
{
	/* tensor.m's activations */
	ANone, ARelu, ASigmoid, ASilu,

	Maxdim	= 1<<15,		/* no side longer */
	Maxelem	= 1<<28,		/* no tensor larger, in floats */
	Maxk	= 15,
	Maxstride = 8,

	KC	= 256,			/* a weight panel 8 x KC (8 KB) in L1 */
	NC	= 128,			/* an activation block KC x NC (128 KB) in L2 */
};

void
tensormodinit(void)
{
	builtinmod("$Tensor", Tensormodtab, Tensormodlen);
}

/* an array as n floats, or an error; called before release() */
static float*
floats(Array *a, uvlong n)
{
	if(a == H)
		error(exNilref);
	if(n > Maxelem || (uvlong)a->len < 4*n || ((uintptr)a->data & 3) != 0)
		error(exBounds);
	return (float*)a->data;
}

static void
dims(int c, int h, int w)
{
	if(c < 1 || h < 1 || w < 1 || c > Maxdim || h > Maxdim || w > Maxdim ||
	   (uvlong)c*h*w > Maxelem)
		error(exBounds);
}

/*
 * e^x to about 2e-6, without the C library (the native kernels have
 * none to spare): 2^(x log2 e), the integer part into the exponent, the
 * fraction by its Taylor series to degree 6.
 */
static float
fexp(float x)
{
	union { float f; u32int u; } v;
	float t, f, p;
	int i;

	if(x > 88.0f)
		x = 88.0f;
	if(x < -87.0f)
		x = -87.0f;
	t = x * 1.44269504088896341f;
	i = (int)t;
	if(t < 0 && (float)i != t)
		i--;
	f = t - (float)i;
	p = 1.0f + f*(0.693147181f + f*(0.240226507f + f*(0.0555041087f + f*(0.00961812911f
		+ f*(0.00133335581f + f*0.000154035304f)))));
	v.u = (u32int)(i + 127) << 23;
	return p * v.f;
}

static float
act1(float x, int act)
{
	switch(act){
	case ARelu:
		return x > 0 ? x : 0;
	case ASigmoid:
		return 1.0f / (1.0f + fexp(-x));
	case ASilu:
		return x / (1.0f + fexp(-x));
	}
	return x;
}

#ifdef NEON
static float32x4_t
vexp(float32x4_t x)
{
	float32x4_t t, f, p;
	int32x4_t i;

	x = vminq_f32(vmaxq_f32(x, vdupq_n_f32(-87.0f)), vdupq_n_f32(88.0f));
	t = vmulq_n_f32(x, 1.44269504088896341f);
	i = vcvtmq_s32_f32(t);			/* floor */
	f = vsubq_f32(t, vcvtq_f32_s32(i));
	p = vdupq_n_f32(0.000154035304f);
	p = vfmaq_f32(vdupq_n_f32(0.00133335581f), p, f);
	p = vfmaq_f32(vdupq_n_f32(0.00961812911f), p, f);
	p = vfmaq_f32(vdupq_n_f32(0.0555041087f), p, f);
	p = vfmaq_f32(vdupq_n_f32(0.240226507f), p, f);
	p = vfmaq_f32(vdupq_n_f32(0.693147181f), p, f);
	p = vfmaq_f32(vdupq_n_f32(1.0f), p, f);
	return vmulq_f32(p, vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(i, vdupq_n_s32(127)), 23)));
}
#endif

/* x[i] = act(x[i] + b) for n floats */
static void
biasact(float *x, int n, float b, int act)
{
	int i;

#ifdef NEON
	float32x4_t vb, v, one, z;

	vb = vdupq_n_f32(b);
	one = vdupq_n_f32(1.0f);
	z = vdupq_n_f32(0.0f);
	for(i = 0; i+4 <= n; i += 4){
		v = vaddq_f32(vld1q_f32(x+i), vb);
		switch(act){
		case ARelu:
			v = vmaxq_f32(v, z);
			break;
		case ASigmoid:
			v = vdivq_f32(one, vaddq_f32(one, vexp(vnegq_f32(v))));
			break;
		case ASilu:
			v = vdivq_f32(v, vaddq_f32(one, vexp(vnegq_f32(v))));
			break;
		}
		vst1q_f32(x+i, v);
	}
#else
	i = 0;
#endif
	for(; i < n; i++)
		x[i] = act1(x[i] + b, act);
}

/*
 * ---- the 8x8 product ----
 * c (row stride ldc) += or = the product of a weight panel (kc steps of
 * 8 rows) and an activation panel (kc steps of 8 columns)
 */

#ifdef NEON
static void
kern8x8(int kc, float *pa, float *pb, float *c, int ldc, int first)
{
	float32x4_t c00, c01, c10, c11, c20, c21, c30, c31;
	float32x4_t c40, c41, c50, c51, c60, c61, c70, c71;
	float32x4_t a0, a1, b0, b1;
	int l;

	if(first){
		c00 = c01 = c10 = c11 = c20 = c21 = c30 = c31 = vdupq_n_f32(0);
		c40 = c41 = c50 = c51 = c60 = c61 = c70 = c71 = vdupq_n_f32(0);
	}else{
		c00 = vld1q_f32(c+0*ldc); c01 = vld1q_f32(c+0*ldc+4);
		c10 = vld1q_f32(c+1*ldc); c11 = vld1q_f32(c+1*ldc+4);
		c20 = vld1q_f32(c+2*ldc); c21 = vld1q_f32(c+2*ldc+4);
		c30 = vld1q_f32(c+3*ldc); c31 = vld1q_f32(c+3*ldc+4);
		c40 = vld1q_f32(c+4*ldc); c41 = vld1q_f32(c+4*ldc+4);
		c50 = vld1q_f32(c+5*ldc); c51 = vld1q_f32(c+5*ldc+4);
		c60 = vld1q_f32(c+6*ldc); c61 = vld1q_f32(c+6*ldc+4);
		c70 = vld1q_f32(c+7*ldc); c71 = vld1q_f32(c+7*ldc+4);
	}
	for(l = 0; l < kc; l++){
		a0 = vld1q_f32(pa); a1 = vld1q_f32(pa+4);
		b0 = vld1q_f32(pb); b1 = vld1q_f32(pb+4);
		pa += 8;
		pb += 8;
		c00 = vfmaq_laneq_f32(c00, b0, a0, 0); c01 = vfmaq_laneq_f32(c01, b1, a0, 0);
		c10 = vfmaq_laneq_f32(c10, b0, a0, 1); c11 = vfmaq_laneq_f32(c11, b1, a0, 1);
		c20 = vfmaq_laneq_f32(c20, b0, a0, 2); c21 = vfmaq_laneq_f32(c21, b1, a0, 2);
		c30 = vfmaq_laneq_f32(c30, b0, a0, 3); c31 = vfmaq_laneq_f32(c31, b1, a0, 3);
		c40 = vfmaq_laneq_f32(c40, b0, a1, 0); c41 = vfmaq_laneq_f32(c41, b1, a1, 0);
		c50 = vfmaq_laneq_f32(c50, b0, a1, 1); c51 = vfmaq_laneq_f32(c51, b1, a1, 1);
		c60 = vfmaq_laneq_f32(c60, b0, a1, 2); c61 = vfmaq_laneq_f32(c61, b1, a1, 2);
		c70 = vfmaq_laneq_f32(c70, b0, a1, 3); c71 = vfmaq_laneq_f32(c71, b1, a1, 3);
	}
	vst1q_f32(c+0*ldc, c00); vst1q_f32(c+0*ldc+4, c01);
	vst1q_f32(c+1*ldc, c10); vst1q_f32(c+1*ldc+4, c11);
	vst1q_f32(c+2*ldc, c20); vst1q_f32(c+2*ldc+4, c21);
	vst1q_f32(c+3*ldc, c30); vst1q_f32(c+3*ldc+4, c31);
	vst1q_f32(c+4*ldc, c40); vst1q_f32(c+4*ldc+4, c41);
	vst1q_f32(c+5*ldc, c50); vst1q_f32(c+5*ldc+4, c51);
	vst1q_f32(c+6*ldc, c60); vst1q_f32(c+6*ldc+4, c61);
	vst1q_f32(c+7*ldc, c70); vst1q_f32(c+7*ldc+4, c71);
}
#else
static void
kern8x8(int kc, float *pa, float *pb, float *c, int ldc, int first)
{
	float acc[8][8];
	int i, j, l;

	for(i = 0; i < 8; i++)
		for(j = 0; j < 8; j++)
			acc[i][j] = first ? 0 : c[i*ldc+j];
	for(l = 0; l < kc; l++){
		for(i = 0; i < 8; i++)
			for(j = 0; j < 8; j++)
				acc[i][j] += pa[i] * pb[j];
		pa += 8;
		pb += 8;
	}
	for(i = 0; i < 8; i++)
		for(j = 0; j < 8; j++)
			c[i*ldc+j] = acc[i][j];
}
#endif

typedef struct Conv Conv;
struct Conv
{
	float	*in;
	int	c, h, w;
	float	*wt;
	int	oc, kh, kw, stride, pad, group;
	float	*bias;
	int	act;
	float	*out;
	int	oh, ow;
};

/* the convolution as a product, for group 1; -1 if it could not have its buffers */
static int
convgemm(Conv *v)
{
	float *pa, *pb, *p, *s, tile[64], x;
	int M, N, K, M8, k0, kc, j0, nc, nc8, i, ii, j, jj, l, t, col, full;
	int ci, ky, kx, kk, iy, ix, hw, one;
	int oy0[NC], ox0[NC];

	M = v->oc;
	K = v->c * v->kh * v->kw;
	N = v->oh * v->ow;
	M8 = (M + 7) & ~7;
	hw = v->h * v->w;
	kk = v->kh * v->kw;
	one = v->kh == 1 && v->kw == 1 && v->stride == 1 && v->pad == 0;

	pa = malloc((uvlong)M8 * K * sizeof(float));
	pb = malloc((uvlong)KC * NC * sizeof(float));
	if(pa == nil || pb == nil){
		free(pa);
		free(pb);
		return -1;
	}

	/* the weights, rows padded to 8 with zeros: block k0, panel i, kc steps of 8 */
	p = pa;
	for(k0 = 0; k0 < K; k0 += KC){
		kc = K-k0 < KC ? K-k0 : KC;
		for(i = 0; i < M8; i += 8)
			for(l = k0; l < k0+kc; l++)
				for(ii = 0; ii < 8; ii++)
					*p++ = i+ii < M ? v->wt[(uvlong)(i+ii)*K + l] : 0;
	}

	for(j0 = 0; j0 < N; j0 += NC){
		nc = N-j0 < NC ? N-j0 : NC;
		nc8 = (nc + 7) & ~7;
		if(!one)
			for(j = 0; j < nc; j++){
				col = j0 + j;
				oy0[j] = (col / v->ow) * v->stride - v->pad;
				ox0[j] = (col % v->ow) * v->stride - v->pad;
			}
		p = pa;
		for(k0 = 0; k0 < K; k0 += KC){
			kc = K-k0 < KC ? K-k0 : KC;
			/* this block of columns, 8 at a time: pb[jj*kc + l*8 + t] */
			for(l = 0; l < kc; l++){
				if(one){
					s = v->in + (uvlong)(k0+l)*N + j0;
					for(jj = 0; jj < nc8; jj += 8)
						for(t = 0; t < 8; t++)
							pb[jj*kc + l*8 + t] = jj+t < nc ? s[jj+t] : 0;
				}else{
					ci = (k0+l) / kk;
					ky = (k0+l) % kk / v->kw;
					kx = (k0+l) % v->kw;
					s = v->in + (uvlong)ci*hw;
					for(jj = 0; jj < nc8; jj += 8)
						for(t = 0; t < 8; t++){
							x = 0;
							if(jj+t < nc){
								iy = oy0[jj+t] + ky;
								ix = ox0[jj+t] + kx;
								if(iy >= 0 && iy < v->h && ix >= 0 && ix < v->w)
									x = s[iy*v->w + ix];
							}
							pb[jj*kc + l*8 + t] = x;
						}
				}
			}
			for(i = 0; i < M8; i += 8)
				for(jj = 0; jj < nc8; jj += 8){
					full = i+8 <= M && jj+8 <= nc;
					if(full)
						kern8x8(kc, p + (uvlong)i*kc, pb + jj*kc, v->out + (uvlong)i*N + j0 + jj, N, k0 == 0);
					else{
						/* an edge: through a tile, keeping only what is inside */
						for(ii = 0; ii < 8; ii++)
							for(t = 0; t < 8; t++)
								tile[ii*8+t] = (k0 != 0 && i+ii < M && jj+t < nc) ?
									v->out[(uvlong)(i+ii)*N + j0+jj+t] : 0;
						kern8x8(kc, p + (uvlong)i*kc, pb + jj*kc, tile, 8, 0);
						for(ii = 0; ii < 8; ii++)
							for(t = 0; t < 8; t++)
								if(i+ii < M && jj+t < nc)
									v->out[(uvlong)(i+ii)*N + j0+jj+t] = tile[ii*8+t];
					}
				}
			p += (uvlong)M8 * kc;
		}
		for(i = 0; i < M; i++)
			biasact(v->out + (uvlong)i*N + j0, nc, v->bias[i], v->act);
	}
	free(pa);
	free(pb);
	return 0;
}

/* a depthwise convolution: each channel by its own kh x kw */
static void
convdw(Conv *v)
{
	int ch, oy, ox, ky, kx, iy, ix, y0, x0, edge;
	float *in, *k, *o, s;

	for(ch = 0; ch < v->c; ch++){
		in = v->in + (uvlong)ch * v->h * v->w;
		k = v->wt + (uvlong)ch * v->kh * v->kw;
		o = v->out + (uvlong)ch * v->oh * v->ow;
		for(oy = 0; oy < v->oh; oy++){
			y0 = oy*v->stride - v->pad;
			for(ox = 0; ox < v->ow; ox++){
				x0 = ox*v->stride - v->pad;
				edge = y0 < 0 || x0 < 0 || y0+v->kh > v->h || x0+v->kw > v->w;
				s = 0;
				for(ky = 0; ky < v->kh; ky++){
					iy = y0 + ky;
					if(edge && (iy < 0 || iy >= v->h))
						continue;
					for(kx = 0; kx < v->kw; kx++){
						ix = x0 + kx;
						if(edge && (ix < 0 || ix >= v->w))
							continue;
						s += in[iy*v->w + ix] * k[ky*v->kw + kx];
					}
				}
				o[oy*v->ow + ox] = s;
			}
		}
		biasact(o, v->oh * v->ow, v->bias[ch], v->act);
	}
}

void
Tensor_conv(void *fp)
{
	F_Tensor_conv *f;
	Conv v;
	int r, icg;

	f = fp;
	v.c = f->c;
	v.h = f->h;
	v.w = f->w;
	v.oc = f->oc;
	v.kh = f->kh;
	v.kw = f->kw;
	v.stride = f->stride;
	v.pad = f->pad;
	v.group = f->group;
	v.act = f->act;
	dims(v.c, v.h, v.w);
	if(v.oc < 1 || v.oc > Maxdim || v.kh < 1 || v.kw < 1 || v.kh > Maxk || v.kw > Maxk ||
	   v.stride < 1 || v.stride > Maxstride || v.pad < 0 || v.pad >= v.kh || v.pad >= v.kw ||
	   v.act < ANone || v.act > ASilu)
		error(exBounds);
	if(v.group == 1)
		icg = v.c;
	else if(v.group == v.c && v.oc == v.c)
		icg = 1;
	else
		error(exBounds);
	if(v.h + 2*v.pad < v.kh || v.w + 2*v.pad < v.kw)
		error(exBounds);
	v.oh = (v.h + 2*v.pad - v.kh) / v.stride + 1;
	v.ow = (v.w + 2*v.pad - v.kw) / v.stride + 1;
	dims(v.oc, v.oh, v.ow);
	v.in = floats(f->in, (uvlong)v.c * v.h * v.w);
	v.wt = floats(f->wt, (uvlong)v.oc * icg * v.kh * v.kw);
	v.bias = floats(f->bias, v.oc);
	v.out = floats(f->out, (uvlong)v.oc * v.oh * v.ow);
	if(f->out == f->in)
		error(exBounds);

	release();
	r = 0;
	if(v.group == 1)
		r = convgemm(&v);
	else
		convdw(&v);
	acquire();
	if(r < 0)
		error(exNomem);
}

void
Tensor_add(void *fp)
{
	F_Tensor_add *f;
	float *a, *b, *o;
	uvlong n, i;

	f = fp;
	if(f->a == H || f->b == H || f->out == H)
		error(exNilref);
	n = f->a->len / 4;
	if(f->b->len != f->a->len || (f->a->len & 3) != 0)
		error(exBounds);
	a = floats(f->a, n);
	b = floats(f->b, n);
	o = floats(f->out, n);
	release();
	for(i = 0; i < n; i++)
		o[i] = a[i] + b[i];
	acquire();
}

void
Tensor_act(void *fp)
{
	F_Tensor_act *f;
	float *in, *o;
	uvlong n;

	f = fp;
	if(f->in == H || f->out == H)
		error(exNilref);
	if(f->act < ANone || f->act > ASilu || (f->in->len & 3) != 0)
		error(exBounds);
	n = f->in->len / 4;
	in = floats(f->in, n);
	o = floats(f->out, n);
	release();
	if(o != in)
		memmove(o, in, n*4);
	biasact(o, n, 0, f->act);
	acquire();
}

void
Tensor_maxpool(void *fp)
{
	F_Tensor_maxpool *f;
	float *in, *o, m, x;
	int c, h, w, k, s, p, oh, ow, ch, oy, ox, ky, kx, iy, ix;

	f = fp;
	c = f->c; h = f->h; w = f->w; k = f->k; s = f->stride; p = f->pad;
	dims(c, h, w);
	if(k < 1 || k > 2*Maxk+1 || s < 1 || s > Maxstride || p < 0 || p > k/2 || h + 2*p < k || w + 2*p < k)
		error(exBounds);
	oh = (h + 2*p - k) / s + 1;
	ow = (w + 2*p - k) / s + 1;
	in = floats(f->in, (uvlong)c*h*w);
	o = floats(f->out, (uvlong)c*oh*ow);
	if(f->in == f->out)
		error(exBounds);
	release();
	for(ch = 0; ch < c; ch++)
		for(oy = 0; oy < oh; oy++)
			for(ox = 0; ox < ow; ox++){
				m = -3.4e38f;
				for(ky = 0; ky < k; ky++){
					iy = oy*s - p + ky;
					if(iy < 0 || iy >= h)
						continue;
					for(kx = 0; kx < k; kx++){
						ix = ox*s - p + kx;
						if(ix < 0 || ix >= w)
							continue;
						x = in[((uvlong)ch*h + iy)*w + ix];
						if(x > m)
							m = x;
					}
				}
				o[((uvlong)ch*oh + oy)*ow + ox] = m;
			}
	acquire();
}

void
Tensor_up2(void *fp)
{
	F_Tensor_up2 *f;
	float *in, *o, *r, *o0;
	int c, h, w, ch, y, x;

	f = fp;
	c = f->c; h = f->h; w = f->w;
	dims(c, 2*h, 2*w);
	in = floats(f->in, (uvlong)c*h*w);
	o = floats(f->out, (uvlong)c*4*h*w);
	if(f->in == f->out)
		error(exBounds);
	release();
	for(ch = 0; ch < c; ch++)
		for(y = 0; y < h; y++){
			r = in + ((uvlong)ch*h + y)*w;
			o0 = o + ((uvlong)ch*2*h + 2*y)*2*w;
			for(x = 0; x < w; x++)
				o0[2*x] = o0[2*x+1] = r[x];
			memmove(o0 + 2*w, o0, 2*w*sizeof(float));
		}
	acquire();
}

void
Tensor_s2d(void *fp)
{
	F_Tensor_s2d *f;
	float *in, *o;
	int c, h, w, h2, w2, q, ch, y, x;
	static const int dy[4] = {0, 1, 0, 1}, dx[4] = {0, 0, 1, 1};

	f = fp;
	c = f->c; h = f->h; w = f->w;
	dims(4*c, h, w);
	if((h|w) & 1)
		error(exBounds);
	h2 = h/2;
	w2 = w/2;
	in = floats(f->in, (uvlong)c*h*w);
	o = floats(f->out, (uvlong)c*h*w);
	if(f->in == f->out)
		error(exBounds);
	release();
	for(q = 0; q < 4; q++)
		for(ch = 0; ch < c; ch++)
			for(y = 0; y < h2; y++)
				for(x = 0; x < w2; x++)
					o[(((uvlong)q*c + ch)*h2 + y)*w2 + x] = in[((uvlong)ch*h + 2*y+dy[q])*w + 2*x+dx[q]];
	acquire();
}

void
Tensor_letterbox(void *fp)
{
	F_Tensor_letterbox *f;
	uchar *pix, *p00, *p01, *p10, *p11;
	float *o, fill, sy, sx, fy, fx;
	int w, h, ow, oh, rw, rh, x, y, ch, y0, x0, y1, x1, src, bgr;
	double scale;

	f = fp;
	w = f->w; h = f->h; ow = f->ow; oh = f->oh;
	scale = f->scale;
	bgr = f->bgr;
	dims(3, h, w);
	dims(3, oh, ow);
	if(f->pix == H)
		error(exNilref);
	if(!(scale > 0 && scale < 1e6) || f->fill < 0 || f->fill > 255 || (uvlong)f->pix->len < (uvlong)3*w*h)
		error(exBounds);
	pix = f->pix->data;
	o = floats(f->out, (uvlong)3*ow*oh);
	rw = (int)(w * scale);
	rh = (int)(h * scale);
	if(rw > ow)
		rw = ow;
	if(rh > oh)
		rh = oh;
	if(rw < 1)
		rw = 1;
	if(rh < 1)
		rh = 1;
	fill = f->fill;
	release();
	/* half-pixel centres, as the usual libraries resize */
	for(y = 0; y < oh; y++)
		for(x = 0; x < ow; x++){
			if(y >= rh || x >= rw){
				for(ch = 0; ch < 3; ch++)
					o[((uvlong)ch*oh + y)*ow + x] = fill;
				continue;
			}
			sy = (y + 0.5f) * h / rh - 0.5f;
			sx = (x + 0.5f) * w / rw - 0.5f;
			if(sy < 0)
				sy = 0;
			if(sx < 0)
				sx = 0;
			y0 = (int)sy;
			x0 = (int)sx;
			if(y0 > h-1)
				y0 = h-1;
			if(x0 > w-1)
				x0 = w-1;
			y1 = y0+1 < h ? y0+1 : h-1;
			x1 = x0+1 < w ? x0+1 : w-1;
			fy = sy - y0;
			fx = sx - x0;
			p00 = pix + 3*((uvlong)y0*w + x0);
			p01 = pix + 3*((uvlong)y0*w + x1);
			p10 = pix + 3*((uvlong)y1*w + x0);
			p11 = pix + 3*((uvlong)y1*w + x1);
			for(ch = 0; ch < 3; ch++){
				/* RGB24 is blue, green, red in memory; channel 0 is red unless bgr */
				src = bgr ? ch : 2-ch;
				o[((uvlong)ch*oh + y)*ow + x] =
					(1-fy)*((1-fx)*p00[src] + fx*p01[src]) + fy*((1-fx)*p10[src] + fx*p11[src]);
			}
		}
	acquire();
}

void
Tensor_toreal(void *fp)
{
	F_Tensor_toreal *f;
	float *t;
	REAL *r;
	uvlong i, n;

	f = fp;
	if(f->t == H || f->out == H)
		error(exNilref);
	if((f->t->len & 3) != 0 || f->out->len != f->t->len/4)
		error(exBounds);
	n = f->out->len;
	t = floats(f->t, n);
	r = (REAL*)f->out->data;
	for(i = 0; i < n; i++)
		r[i] = t[i];
}

void
Tensor_fromreal(void *fp)
{
	F_Tensor_fromreal *f;
	float *t;
	REAL *r;
	uvlong i, n;

	f = fp;
	if(f->r == H || f->out == H)
		error(exNilref);
	n = f->r->len;
	if((uvlong)f->out->len != 4*n)
		error(exBounds);
	t = floats(f->out, n);
	r = (REAL*)f->r->data;
	for(i = 0; i < n; i++)
		t[i] = r[i];
}

void
Tensor_kind(void *fp)
{
	F_Tensor_kind *f;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
#ifdef NEON
	retstr("neon", f->ret);
#else
	retstr("c", f->ret);
#endif
}
