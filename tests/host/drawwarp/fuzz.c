/*
 * The draw device's warp (libmemdraw/warp.c), built with AddressSanitizer
 * and UndefinedBehaviorSanitizer by tests/host/drawwarp_fuzz_test.sh, given
 * what a client may send: images of every channel format, at any origin,
 * replicated or not, with clip rectangles that do and do not fit; any
 * destination point, rectangle and source point; matrices bounded by
 * warpok() and matrices that are not; the upscale flag on any matrix;
 * smooth or not; an image warped onto itself.  Each image's pixels are
 * allocated at exactly their size, so a read or write past them is the
 * sanitizer's report (in the emulator they are in a pool, whose blocks it
 * cannot see).
 *
 * With -l, the same through layers (memlaffinewarp, which the draw device
 * calls): windows on a screen, some covering others, saved or not, warped
 * onto, from and within one another and the screen.
 *
 *	fuzz [-l] [-n iterations] [-s seed]
 */
#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "pool.h"
#include "memlayer.h"

Pool *imagmem;

/*
 * The image pool's blocks as the emulator's allocator makes them
 * (emu/port/alloc.c): the size asked rounded with the block's header and
 * tail to its quantum, 127 for images.  What lies past the size asked but
 * within that is the block's own; past it is another's, and that is what
 * the sanitizer is to see.  (The warp's own test images, in plain mode,
 * are not from here: their pixels are exactly their size.)
 */
void*
poolalloc(Pool *p, ulong n)
{
	USED(p);
	static Bhdr b;
	ulong h;

	/* pool.h's BHDRSIZE, measured from a block rather than through nil */
	h = (uchar*)&b.u.data - (uchar*)&b + sizeof(Btail);
	return calloc(1, ((n + h + 127) & ~(ulong)127) - h);
}

void
poolfree(Pool *p, void *v)
{
	USED(p);
	free(v);
}

/* lib9's, which the emulator gives and this harness does not link */
void*
mallocz(ulong n, int clr)
{
	USED(clr);
	return calloc(1, n);
}

int
_tas(int *p)
{
	int v;

	v = *p;
	*p = 1;
	return v;
}

void
_assert(char *s)
{
	fprint(2, "assert failed: %s\n", s);
	abort();
}

char*
poolname(Pool *p)
{
	USED(p);
	return "image";
}

void
poolsetcompact(Pool *p, void (*f)(void*, void*))
{
	USED(p);
	USED(f);
}

int
hwdraw(Memdrawparam *p)
{
	USED(p);
	return 0;
}

static uvlong rs;

static ulong
rnd(void)
{
	rs ^= rs << 13;
	rs ^= rs >> 7;
	rs ^= rs << 17;
	return (ulong)(rs >> 11);
}

static long
pick(long lo, long hi)
{
	return lo + (long)(rnd() % (ulong)(hi - lo + 1));
}

static long
edgy(void)
{
	static long v[] = {
		0, 1, -1, 2, -2, 0x7FFFFFFF, -0x7FFFFFFF-1, 0x3FFFFFFF, -0x40000000,
		1<<24, -(1<<24), (1<<24)+1, -(1<<24)-1, 1<<13, -(1<<13), 4096, 2731, 16384,
		1<<20, -(1<<20), 700000, -700000,
	};
	return v[rnd() % nelem(v)];
}

static ulong chans[] = {
	GREY1, GREY2, GREY4, GREY8, CMAP8, RGB15, RGB16, RGB24, RGBA32, ARGB32,
	XRGB32, BGR24, ABGR32, XBGR32,
	CHAN4(CIgnore, 1, CBlue, 5, CGreen, 5, CRed, 5),	/* BGR15 */
	CHAN2(CGrey, 8, CAlpha, 8),				/* a general one */
	CHAN3(CRed, 2, CGreen, 3, CBlue, 3),			/* another */
};

typedef struct Img Img;
struct Img
{
	Memimage *i;
	Memdata *md;
	uchar *buf;
};

static int
mkimg(Img *m)
{
	Rectangle r;
	ulong chan, l;
	long x, y, dx, dy;
	int d;
	unsigned long long n;

	chan = chans[rnd() % nelem(chans)];
	d = chantodepth(chan);
	if(rnd() % 4 == 0){
		x = pick(-800000, 800000);
		y = pick(-800000, 800000);
	}else{
		x = pick(-20, 20);
		y = pick(-20, 20);
	}
	dx = pick(1, 40);
	dy = pick(1, 30);
	r = Rect(x, y, x+dx, y+dy);
	l = wordsperline(r, d);
	n = (unsigned long long)l * dy * sizeof(ulong);
	m->md = calloc(1, sizeof(Memdata));
	m->buf = malloc(n);
	if(m->md == nil || m->buf == nil)
		return -1;
	for(unsigned long long k = 0; k < n; k++)
		m->buf[k] = rnd();
	m->md->bdata = m->buf;
	m->md->ref = 1;
	m->i = allocmemimaged(r, chan, m->md);
	if(m->i == nil)
		return -1;
	switch(rnd() % 4){
	case 0:	/* replicated, clipped wide */
		m->i->flags |= Frepl;
		m->i->clipr = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
		break;
	case 1:	/* a clip inside */
		m->i->clipr = Rect(x+pick(0, dx/2), y+pick(0, dy/2), x+pick(dx/2, dx), y+pick(dy/2, dy));
		break;
	case 2:	/* a clip partly outside, or none of it in */
		m->i->clipr = Rect(x+pick(-50, 50), y+pick(-50, 50), x+pick(-50, 90), y+pick(-50, 90));
		break;
	}
	return 0;
}

static void
freeimg(Img *m)
{
	if(m->i != nil)
		free(m->i);
	free(m->buf);
	free(m->md);
}

static Point
pt(Memimage *i)
{
	if(rnd() % 5 == 0)
		return Pt(edgy(), edgy());
	return Pt(i->r.min.x + pick(-60, 60), i->r.min.y + pick(-60, 60));
}

/* a screen's channels: a display's own, unless -x asks for any */
static int anyscreen;
static ulong screenchans[] = { XRGB32, RGB24, RGB16, CMAP8, GREY8, ARGB32, XBGR32 };

static ulong
screenchan(void)
{
	if(anyscreen)
		return chans[rnd() % nelem(chans)];
	return screenchans[rnd() % nelem(screenchans)];
}

static Warp
mkwarp(void)
{
	Warp w;
	int i, j;

	memset(&w, 0, sizeof w);
	for(i = 0; i < 2; i++)
		for(j = 0; j < 3; j++)
			switch(rnd() % 4){
			case 0:	w.m[i][j] = edgy(); break;
			case 1:	w.m[i][j] = pick(-20000, 20000); break;
			case 2:	w.m[i][j] = (i == j)? (1<<13) / pick(1, 4) : 0; break;
			default:	w.m[i][j] = (long)(int)rnd(); break;
			}
	if(rnd() % 4 != 0)
		for(i = 0; i < 2; i++)
			for(j = 0; j < 2; j++)
				if(w.m[i][j] > (1<<24) || w.m[i][j] < -(1<<24))
					w.m[i][j] = pick(-(1<<24), 1<<24) >> (rnd() % 12);
	w.m[2][2] = 1<<13;
	w.flags = rnd() % 3 == 0;
	return w;
}

static void
layers(long n)
{
	Memimage *screen, *fill, *l[5], *dst, *src;
	Memscreen *scr;
	Img plain;
	Warp w;
	Rectangle r;
	long k, done;
	int i, nl;

	done = 0;
	for(k = 0; k < n; k++){
		screen = allocmemimage(Rect(0, 0, pick(40, 220), pick(40, 160)), screenchan());
		fill = allocmemimage(Rect(0, 0, 1, 1), screen->chan);
		if(screen == nil || fill == nil)
			continue;
		fill->flags |= Frepl;
		fill->clipr = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
		scr = calloc(1, sizeof(Memscreen));
		scr->image = screen;
		scr->fill = fill;
		nl = pick(1, nelem(l));
		for(i = 0; i < nl; i++){
			r.min = Pt(pick(-20, screen->r.max.x), pick(-20, screen->r.max.y));
			r.max = addpt(r.min, Pt(pick(1, 120), pick(1, 90)));
			l[i] = memlalloc(scr, r, nil, nil, DWhite);
			if(l[i] == nil){
				nl = i;
				break;
			}
			if(rnd() % 3 == 0)
				l[i]->clipr = Rect(r.min.x+pick(-30, 30), r.min.y+pick(-30, 30), r.max.x+pick(-30, 30), r.max.y+pick(-30, 30));
		}
		memset(&plain, 0, sizeof plain);
		if(mkimg(&plain) < 0 || nl == 0){
			freeimg(&plain);
			goto Free;
		}
		for(i = 0; i < 8; i++){
			dst = (rnd() % 5 == 0)? screen: l[rnd() % nl];
			switch(rnd() % 4){
			case 0:	src = plain.i; break;
			case 1:	src = dst; break;
			case 2:	src = screen; break;
			default:	src = l[rnd() % nl]; break;
			}
			w = mkwarp();
			r.min = pt(dst);
			r.max = addpt(r.min, Pt(pick(-10, 80), pick(-10, 80)));
			memlaffinewarp(dst, pt(dst), r, src, pt(src), nil, ZP, &w, rnd() % 2, (rnd()%2)? SoverD: S);
			done++;
			if(rnd() % 4 == 0)
				memltofront(l[rnd() % nl]);
		}
		freeimg(&plain);
	Free:
		for(i = nl-1; i >= 0; i--)
			memldelete(l[i]);
		free(scr);
		freememimage(fill);
		freememimage(screen);
	}
	print("%ld warps through layers\n", done);
}

int
main(int argc, char **argv)
{
	long n, k, done, refused;
	Img d, s;
	Warp w;
	Rectangle r;
	Point dp, sp;
	int i, j, smooth, same;

	int lflag;

	n = 200000;
	lflag = 0;
	rs = 0x9E3779B97F4A7C15ULL;
	while(argc > 1 && argv[1][0] == '-' && (argv[1][1] == 'l' || argv[1][1] == 'x')){
		if(argv[1][1] == 'l')
			lflag = 1;
		else
			anyscreen = 1;
		argc--;
		argv++;
	}
	for(i = 1; i+1 < argc; i += 2){
		if(strcmp(argv[i], "-n") == 0)
			n = strtol(argv[i+1], nil, 0);
		else if(strcmp(argv[i], "-s") == 0)
			rs ^= strtoull(argv[i+1], nil, 0) * 0xBF58476D1CE4E5B9ULL;
	}
	memimageinit();
	if(lflag){
		layers(n);
		return 0;
	}
	done = refused = 0;
	for(k = 0; k < n; k++){
		memset(&d, 0, sizeof d);
		memset(&s, 0, sizeof s);
		if(mkimg(&d) < 0){
			freeimg(&d);
			continue;
		}
		same = rnd() % 8 == 0;
		if(!same && mkimg(&s) < 0){
			freeimg(&d);
			freeimg(&s);
			continue;
		}
		memset(&w, 0, sizeof w);
		for(i = 0; i < 2; i++)
			for(j = 0; j < 3; j++)
				switch(rnd() % 4){
				case 0:	w.m[i][j] = edgy(); break;
				case 1:	w.m[i][j] = pick(-20000, 20000); break;
				case 2:	w.m[i][j] = (i == j)? (1<<13) / pick(1, 4) : 0; break;
				default:	w.m[i][j] = (long)(int)rnd(); break;
				}
		/* most matrices within warpok's bounds, so the pixels are reached */
		if(rnd() % 4 != 0)
			for(i = 0; i < 2; i++)
				for(j = 0; j < 2; j++)
					if(w.m[i][j] > (1<<24) || w.m[i][j] < -(1<<24))
						w.m[i][j] = pick(-(1<<24), 1<<24) >> (rnd() % 12);
		w.m[2][2] = 1<<13;
		w.flags = rnd() % 3 == 0;
		smooth = rnd() % 2;
		dp = pt(d.i);
		r.min = pt(d.i);
		r.max = addpt(r.min, Pt(pick(-10, 80), pick(-10, 80)));
		if(rnd() % 10 == 0)
			r = Rect(edgy(), edgy(), edgy(), edgy());
		sp = pt(same? d.i: s.i);
		if(!warpok(&w))
			refused++;
		memaffinewarp(d.i, dp, r, same? d.i: s.i, sp, nil, ZP, &w, smooth, (rnd()%2)? SoverD: S);
		done++;
		freeimg(&d);
		if(!same)
			freeimg(&s);
	}
	print("%ld warps, %ld with a matrix warpok refuses\n", done, refused);
	return 0;
}
