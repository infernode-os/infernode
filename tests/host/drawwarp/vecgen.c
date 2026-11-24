/*
 * Run on 9front: the answers its libmemdraw gives for affine warps, for
 * tests/drawwarp_test.b to compare InferNode's draw device with.
 *
 * Each line is one warp: the source image (its channels, whether it is
 * replicated, its rectangle; its pixels the generator's bytes from the
 * case's number), the destination (channels, rectangle, fill colour),
 * the warp's dp, r, sp, matrix (the six entries of its first two rows,
 * 19.13 fixed point), mkwarp's flags and smooth, then the SHA-256 of
 * the destination's pixels after it, as unloadmemimage gives them.
 * Given a case's number, it prints that case's pixels in hex instead.
 *
 * 9front-vectors.txt was made on 9front 11952 (amd64) from 9front's own
 * warp.c with one change, a channel's result masked to its byte at the
 * end of bilinear():
 *
 *	sed 's/(\(lerp\(c0[₀₁₂₃], c1[₀₁₂₃], s->Δy\)\))/(\1 \& 0xFF)/' \
 *		/sys/src/libmemdraw/warp.c > w9.c
 *	6c vecgen.c w9.c && 6l -o vecgen vecgen.6 w9.6 && ./vecgen > 9front-vectors.txt
 *
 * There the vertical lerp's operands are uchars, which 6c subtracts as
 * unsigned: where a channel falls between the rows its difference wraps,
 * and the result, not masked, carries 2^19 into the channel above it
 * (blue's into red's bit 3, alpha's into green's).  9front's own smooth
 * warps have those bits wrong; cases 23 28 30 32 34 36 differ from the
 * library as installed in them alone.  InferNode's warp blends right.
 */
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>
#include <libsec.h>

typedef struct Case Case;
struct Case
{
	char	*schan;
	int	srepl;
	Rectangle	sr;
	char	*dchan;
	Rectangle	dr;
	ulong	fill;
	Point	dp;
	Rectangle	r;
	Point	sp;
	long	m[6];
	int	flags;
	int	smooth;
};

#define R(a,b,c,d)	{{a,b},{c,d}}
#define P(a,b)	{a,b}
#define ID	{8192,0,0, 0,8192,0}
#define UP2	{4096,0,0, 0,4096,0}
#define UP3	{2731,0,0, 0,2731,0}
#define DOWN2	{16384,0,0, 0,16384,0}
#define ROT	{7094,-4096,6*8192, 4096,7094,-3*8192}
#define SHEAR	{8192,2048,1234, 1024,8192,-5000}

Case cases[] = {
	/* identity, each destination format from an RGBA source */
	{"r8g8b8a8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "r5g6b5", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "k8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "m8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "k1", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "k2", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "k4", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "a8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "x1r5g5b5", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "b8g8r8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "a8b8g8r8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "x8b8g8r8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	/* each source format to one destination */
	{"k1", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"k4", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"m8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"r5g6b5", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"x1r5g5b5", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"a8r8g8b8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	{"b8g8r8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), ID, 0, 0},
	/* upscales: the integer-upscale path and the general one, smooth too */
	{"r8g8b8", 0, R(0,0,8,6), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), UP2, 1, 0},
	{"r8g8b8", 0, R(0,0,8,6), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), UP2, 0, 0},
	{"r8g8b8", 0, R(0,0,8,6), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), UP2, 0, 1},
	{"r8g8b8", 0, R(0,0,8,6), "r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), UP3, 1, 0},
	{"r8g8b8", 0, R(0,0,8,6), "k8", R(0,0,24,20), 0x336699FF, P(3,2), R(1,1,23,19), P(1,1), UP2, 1, 0},
	/* a downscale, smooth */
	{"r8g8b8", 0, R(0,0,32,24), "x8r8g8b8", R(0,0,16,12), 0x336699FF, P(0,0), R(0,0,16,12), P(0,0), DOWN2, 0, 1},
	/* a rotation and a shear with translation, plain and smooth */
	{"r8g8b8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), ROT, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), ROT, 0, 1},
	{"r8g8b8", 0, R(0,0,16,12), "r5g6b5", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), SHEAR, 0, 0},
	{"r8g8b8", 0, R(0,0,16,12), "k1", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), SHEAR, 0, 1},
	/* a replicated source past its edges */
	{"r8g8b8", 1, R(0,0,5,3), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), SHEAR, 0, 0},
	{"r8g8b8", 1, R(0,0,5,3), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), ROT, 0, 1},
	/* images away from the origin; dp, r and sp of their own */
	{"r8g8b8", 0, R(10,20,26,32), "x8r8g8b8", R(100,50,124,70), 0x336699FF, P(105,53), R(102,52,120,68), P(12,21), ROT, 0, 0},
	{"r8g8b8", 0, R(10,20,26,32), "k4", R(100,50,124,70), 0x336699FF, P(105,53), R(102,52,120,68), P(12,21), SHEAR, 0, 1},
	/* blending: a source with alpha over the destination */
	{"r8g8b8a8", 0, R(0,0,16,12), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), ROT, 0, 0},
	{"r8g8b8a8", 0, R(0,0,16,12), "r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), ROT, 0, 1},
	{"a8r8g8b8", 0, R(0,0,8,6), "x8r8g8b8", R(0,0,24,20), 0x336699FF, P(0,0), R(0,0,24,20), P(0,0), UP2, 1, 0},
};

static ulong seed;

static uchar
gen(void)
{
	seed = seed*1103515245 + 12345;
	return seed>>16;
}

static void
prrect(Rectangle r)
{
	print(" %d %d %d %d", r.min.x, r.min.y, r.max.x, r.max.y);
}

void
main(int argc, char **argv)
{
	Memimage *s, *d;
	Warp w;
	Case *c;
	uchar *buf, digest[SHA2_256dlen];
	int i, j, n;
	char cs[16];
	int only;

	only = argc > 1? atoi(argv[1]): 0;
	memimageinit();
	for(i = 0; i < nelem(cases); i++){
		c = &cases[i];
		if(only && only != i+1)
			continue;
		s = allocmemimage(c->sr, strtochan(c->schan));
		d = allocmemimage(c->dr, strtochan(c->dchan));
		if(s == nil || d == nil)
			sysfatal("allocmemimage: %r");
		if(c->srepl){
			s->flags |= Frepl;
			s->clipr = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
		}
		n = bytesperline(c->sr, s->depth)*Dy(c->sr);
		buf = malloc(n);
		seed = i+1;
		for(j = 0; j < n; j++)
			buf[j] = gen();
		if(loadmemimage(s, c->sr, buf, n) != n)
			sysfatal("loadmemimage: %r");
		free(buf);
		memfillcolor(d, c->fill);

		memset(&w, 0, sizeof w);
		w.m[0][0] = c->m[0]; w.m[0][1] = c->m[1]; w.m[0][2] = c->m[2];
		w.m[1][0] = c->m[3]; w.m[1][1] = c->m[4]; w.m[1][2] = c->m[5];
		w.m[2][2] = 1<<13;
		w.flags = c->flags;
		memaffinewarp(d, c->dp, c->r, s, c->sp, nil, ZP, &w, c->smooth, SoverD);

		n = bytesperline(c->dr, d->depth)*Dy(c->dr);
		buf = malloc(n);
		if(unloadmemimage(d, c->dr, buf, n) != n)
			sysfatal("unloadmemimage: %r");
		if(only == i+1){
			for(j = 0; j < n; j++)
				print("%.2ux%s", buf[j], (j+1)%32? "": "\n");
			exits(nil);
		}
		sha2_256(buf, n, digest, nil);
		free(buf);

		print("w %d %s %d", i+1, chantostr(cs, s->chan), c->srepl);
		prrect(c->sr);
		print(" %s", chantostr(cs, d->chan));
		prrect(c->dr);
		print(" %.8lux %d %d", c->fill, c->dp.x, c->dp.y);
		prrect(c->r);
		print(" %d %d", c->sp.x, c->sp.y);
		for(j = 0; j < 6; j++)
			print(" %ld", c->m[j]);
		print(" %d %d ", c->flags, c->smooth);
		for(j = 0; j < SHA2_256dlen; j++)
			print("%.2ux", digest[j]);
		print("\n");
		freememimage(s);
		freememimage(d);
	}
	exits(nil);
}
