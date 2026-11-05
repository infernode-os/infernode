/*
 * audiomix -- the shared audio device's arithmetic.  See audiomix.h.
 */
#ifdef EMU
#include	"dat.h"		/* lib9.h, in the emulator, wants its types first */
#else
#include	"lib9.h"	/* the host test (tests/host/audiomix_test.sh) */
#endif
#include	"audiomix.h"

/*
 * G.711.  The encoders take 16-bit linear samples; the decoders give
 * them back at 16-bit scale.  After the Sun reference implementation,
 * which every G.711 in use follows.
 */
static int
ulaw2lin(int u)
{
	int t;

	u = ~u & 0xFF;
	t = ((u & 0x0F) << 3) + 0x84;
	t <<= (u & 0x70) >> 4;
	return (u & 0x80) ? 0x84 - t : t - 0x84;
}

static int
lin2ulaw(int pcm)
{
	int sign, exp, mant, mask;

	sign = 0;
	if(pcm < 0){
		pcm = -pcm;
		sign = 0x80;
	}
	if(pcm > 32635)
		pcm = 32635;
	pcm += 0x84;
	exp = 7;
	for(mask = 0x4000; (pcm & mask) == 0 && exp > 0; mask >>= 1)
		exp--;
	mant = (pcm >> (exp + 3)) & 0x0F;
	return ~(sign | (exp << 4) | mant) & 0xFF;
}

static int
alaw2lin(int a)
{
	int t, seg;

	a ^= 0x55;
	t = (a & 0x0F) << 4;
	seg = (a & 0x70) >> 4;
	switch(seg){
	case 0:
		t += 8;
		break;
	case 1:
		t += 0x108;
		break;
	default:
		t += 0x108;
		t <<= seg - 1;
		break;
	}
	return (a & 0x80) ? t : -t;
}

static int segaend[8] = {0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF};

static int
lin2alaw(int pcm)
{
	int mask, seg, aval;

	pcm >>= 3;
	if(pcm >= 0)
		mask = 0xD5;
	else{
		mask = 0x55;
		pcm = -pcm - 1;
	}
	for(seg = 0; seg < 8; seg++)
		if(pcm <= segaend[seg])
			break;
	if(seg >= 8)
		return 0x7F ^ mask;
	aval = seg << 4;
	if(seg < 2)
		aval |= (pcm >> 1) & 0x0F;
	else
		aval |= (pcm >> seg) & 0x0F;
	return aval ^ mask;
}

int
afmtbytes(Afmt *f)
{
	return f->chans * (f->bits / 8);
}

int
afmtok(Afmt *f)
{
	if(f->rate < 8000 || f->rate > Mixrate)	/* streamwrite's buffers assume at most 6x */
		return 0;
	if(f->chans != 1 && f->chans != 2)
		return 0;
	switch(f->enc){
	case Apcm:
		return f->bits == 8 || f->bits == 16;
	case Aulaw:
	case Aalaw:
		return f->bits == 8;
	}
	return 0;
}

static int
sample(Afmt *f, uchar *p)
{
	switch(f->enc){
	case Aulaw:
		return ulaw2lin(*p);
	case Aalaw:
		return alaw2lin(*p);
	}
	if(f->bits == 8)
		return (*p - 128) << 8;
	return (short)(p[0] | (p[1] << 8));
}

static void
putsample(Afmt *f, int v, uchar *p)
{
	switch(f->enc){
	case Aulaw:
		*p = lin2ulaw(v);
		return;
	case Aalaw:
		*p = lin2alaw(v);
		return;
	}
	if(f->bits == 8){
		*p = (v >> 8) + 128;
		return;
	}
	p[0] = v;
	p[1] = v >> 8;
}

/* n bytes of f to stereo frames in out; a part frame at the end is left. */
int
decodepcm(Afmt *f, uchar *b, int n, short *out)
{
	int fb, sb, i, l, r;

	fb = afmtbytes(f);
	sb = f->bits / 8;
	n /= fb;
	for(i = 0; i < n; i++, b += fb){
		l = sample(f, b);
		r = f->chans == 2 ? sample(f, b + sb) : l;
		out[2*i] = l;
		out[2*i+1] = r;
	}
	return n;
}

/* n stereo frames to f's bytes in out; returns the bytes. */
int
encodepcm(Afmt *f, short *in, int n, uchar *out)
{
	int sb, i;
	uchar *p;

	sb = f->bits / 8;
	p = out;
	for(i = 0; i < n; i++){
		if(f->chans == 2){
			putsample(f, in[2*i], p);
			putsample(f, in[2*i+1], p + sb);
			p += 2*sb;
		}else{
			putsample(f, (in[2*i] + in[2*i+1]) / 2, p);
			p += sb;
		}
	}
	return p - out;
}

void
resampinit(Resamp *r, int ri, int ro)
{
	r->ri = ri;
	r->ro = ro;
	r->pos = 0;
	r->primed = 0;
}

int
resampmax(Resamp *r, int nin)
{
	uvlong span;

	span = (uvlong)(nin + 1) * r->ro;
	if(span <= r->pos)
		return 1;
	return (span - r->pos) / r->ri + 2;
}

/*
 * Linear interpolation between neighbouring input frames.  The sequence
 * interpolated is the frame before this buffer (last) and then the
 * buffer, so a stream converted in pieces comes out as though converted
 * whole.  Positions are counted in input frames times the output rate,
 * stepping by the input rate, so a second of input is a second of
 * output whatever the rates: a step rounded to fixed point drifted (8000
 * to 48000 gave 48003 frames a second).  Equal rates come out unchanged,
 * one frame late.
 */
int
resample(Resamp *r, short *in, int nin, short *out)
{
	int n, idx, c, ro;
	uvlong frac;
	short *a, *b;

	if(nin <= 0)
		return 0;
	if(!r->primed){
		r->last[0] = in[0];
		r->last[1] = in[1];
		r->primed = 1;
		r->pos = 0;
	}
	ro = r->ro;
	n = 0;
	while((idx = r->pos / ro) < nin){
		frac = r->pos % ro;
		a = idx == 0 ? r->last : in + 2*(idx - 1);
		b = in + 2*idx;
		for(c = 0; c < 2; c++)
			out[2*n+c] = a[c] + (int)(((vlong)b[c] - a[c]) * (vlong)frac / ro);
		n++;
		r->pos += r->ri;
	}
	r->last[0] = in[2*(nin-1)];
	r->last[1] = in[2*(nin-1)+1];
	r->pos -= (uvlong)nin * ro;
	return n;
}

void
fringinit(Fring *r, short *b, int cap)
{
	r->b = b;
	r->cap = cap;
	r->head = 0;
	r->len = 0;
}

/*
 * Put n frames.  With dropold the newest are kept and the oldest the
 * queue cannot also hold are dropped; without it what does not fit is
 * not taken.  Returns the frames taken.
 */
int
fringput(Fring *r, short *s, int n, int dropold)
{
	int over, tail, k, i;

	if(dropold){
		if(n > r->cap){
			s += 2*(n - r->cap);
			n = r->cap;
		}
		over = r->len + n - r->cap;
		if(over > 0){
			r->head = (r->head + over) % r->cap;
			r->len -= over;
		}
	}else if(n > r->cap - r->len)
		n = r->cap - r->len;
	tail = (r->head + r->len) % r->cap;
	for(i = 0; i < n; i += k){
		k = r->cap - tail;
		if(k > n - i)
			k = n - i;
		memmove(r->b + 2*tail, s + 2*i, k * 2 * sizeof(short));
		tail = (tail + k) % r->cap;
	}
	r->len += n;
	return n;
}

int
fringget(Fring *r, short *d, int n)
{
	int k, i;

	if(n > r->len)
		n = r->len;
	for(i = 0; i < n; i += k){
		k = r->cap - r->head;
		if(k > n - i)
			k = n - i;
		memmove(d + 2*i, r->b + 2*r->head, k * 2 * sizeof(short));
		r->head = (r->head + k) % r->cap;
	}
	r->len -= n;
	return n;
}

void
bringinit(Bring *r, uchar *b, int cap)
{
	r->b = b;
	r->cap = cap;
	r->head = 0;
	r->len = 0;
}

int
bringput(Bring *r, uchar *s, int n, int dropold)
{
	int over, tail, k, i;

	if(dropold){
		if(n > r->cap){
			s += n - r->cap;
			n = r->cap;
		}
		over = r->len + n - r->cap;
		if(over > 0){
			r->head = (r->head + over) % r->cap;
			r->len -= over;
		}
	}else if(n > r->cap - r->len)
		n = r->cap - r->len;
	tail = (r->head + r->len) % r->cap;
	for(i = 0; i < n; i += k){
		k = r->cap - tail;
		if(k > n - i)
			k = n - i;
		memmove(r->b + tail, s + i, k);
		tail = (tail + k) % r->cap;
	}
	r->len += n;
	return n;
}

int
bringget(Bring *r, uchar *d, int n)
{
	int k, i;

	if(n > r->len)
		n = r->len;
	for(i = 0; i < n; i += k){
		k = r->cap - r->head;
		if(k > n - i)
			k = n - i;
		memmove(d + i, r->b + r->head, k);
		r->head = (r->head + k) % r->cap;
	}
	r->len -= n;
	return n;
}

/* acc += src * gain, the gain moving from g0 to g1 across the frames. */
void
mixadd(int *acc, short *src, int frames, int g0, int g1)
{
	int i, g;

	for(i = 0; i < frames; i++){
		g = g0 + (g1 - g0) * i / (frames > 0 ? frames : 1);
		acc[2*i] += src[2*i] * g / Gainone;
		acc[2*i+1] += src[2*i+1] * g / Gainone;
	}
}

void
mixclip(int *acc, short *out, int frames)
{
	int i, v;

	for(i = 0; i < 2*frames; i++){
		v = acc[i];
		if(v > 32767)
			v = 32767;
		else if(v < -32768)
			v = -32768;
		out[i] = v;
	}
}
