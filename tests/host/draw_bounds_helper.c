#include "lib9.h"
#include "draw.h"
#include "memdraw.h"

static int arcdrew;
Memimage *memopaque;

Memimage* allocmemimage(Rectangle r, ulong chan) { (void)r; (void)chan; arcdrew = 1; return nil; }
void freememimage(Memimage *i) { (void)i; }
void memfillcolor(Memimage *i, ulong c) { (void)i; (void)c; }
void memfillpoly(Memimage *i, Point *p, int n, int w, Memimage *s, Point sp, int op)
{ (void)i; (void)p; (void)n; (void)w; (void)s; (void)sp; (void)op; }
void memellipse(Memimage *i, Point p, int a, int b, int t, Memimage *s, Point sp, int op)
{ (void)i; (void)p; (void)a; (void)b; (void)t; (void)s; (void)sp; (void)op; arcdrew = 1; }
void memimagedraw(Memimage *d, Rectangle r, Memimage *s, Point sp, Memimage *m, Point mp, int op)
{ (void)d; (void)r; (void)s; (void)sp; (void)m; (void)mp; (void)op; }
void memdraw(Memimage *d, Rectangle r, Memimage *s, Point sp, Memimage *m, Point mp, int op)
{ (void)d; (void)r; (void)s; (void)sp; (void)m; (void)mp; (void)op; }
void icossin(int a, int *c, int *s) { (void)a; *c = *s = 0; }

static int
check(int ok, char *what)
{
	if(ok)
		return 0;
	fprint(2, "FAIL: %s\n", what);
	return 1;
}

uchar*
byteaddr(Memimage *image, Point p)
{
	return image->data->bdata + image->zero +
		p.y*image->width*sizeof(ulong) + p.x*image->depth/8;
}

int
main(void)
{
	uchar compressed[140];
	uchar repeat[2], pixels[3];
	Memdata data;
	Memimage image;
	int i, failed, c, s;

	failed = 0;
	failed += check(!badrect(Rect(0, 0, 1, 1)), "ordinary rectangle rejected");
	failed += check(badrect(Rect(0, 0, 0, 1)), "zero-width rectangle accepted");
	failed += check(badrect(Rect(0, 0, 1<<26, 1)), "overflowing x coordinate accepted");
	failed += check(badrect(Rect(0, 1<<28, 1, (1<<28)+1)),
		"overflowing y offset accepted");
	failed += check(bytesperline(Rect(-2, 0, -1, 1), 8) == 1,
		"negative-coordinate scan line is mis-sized");
	icossin2((int)(1U<<31), (int)(1U<<31), &c, &s);
	failed += check(c == -724 && s == -724,
		"icossin2 overflows at the minimum integer coordinate");
	arcdrew = 0;
	memarc(nil, ZP, 1, 1, 0, nil, ZP, 0, 0, S);
	failed += check(!arcdrew, "zero-angle arc attempted to draw");

	memset(compressed, 0x5A, sizeof compressed);
	compressed[0] = 0xFF;
	compressed[1] = 0;
	_twiddlecompressed(compressed, 2);
	failed += check(compressed[1] == 0xFF, "in-range compressed byte not transformed");
	for(i = 2; i < sizeof compressed; i++)
		if(compressed[i] != 0x5A){
			failed += check(0, "compressed image transform crossed its input bound");
			break;
		}

	memset(&data, 0, sizeof data);
	memset(&image, 0, sizeof image);
	memset(pixels, 0x5A, sizeof pixels);
	data.bdata = pixels;
	image.data = &data;
	image.r = image.clipr = Rect(0, 0, 3, 1);
	image.depth = 8;
	image.width = 1;
	repeat[0] = repeat[1] = 0;	/* repeat three bytes, offset one */
	failed += check(cloadmemimage(&image, image.r, repeat, sizeof repeat) == 2,
		"leading repeat command was not decoded");
	failed += check(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0,
		"leading repeat disclosed uninitialized decoder memory");

	if(failed != 0)
		return 1;
	print("PASS: draw geometry and compressed-image bounds\n");
	return 0;
}
