#pragma	src	"/usr/inferno/libmemdraw"

typedef struct	Memimage Memimage;
typedef struct	Memdata Memdata;
typedef struct	Memsubfont Memsubfont;
typedef struct	Memlayer Memlayer;
typedef struct	Memcmap Memcmap;
typedef struct	Memdrawparam	Memdrawparam;

#pragma incomplete Memlayer

/*
 * Memdata is allocated from main pool, but .data from the image pool.
 * Memdata is allocated separately to permit patching its pointer after
 * compaction when windows share the image data.
 * The first word of data is a back pointer to the Memdata, to find
 * The word to patch.
 */

struct Memdata
{
	ulong	*base;	/* allocated data pointer */
	uchar	*bdata;	/* pointer to first byte of actual data; word-aligned */
	int		ref;		/* number of Memimages using this data */
	void*	imref;
	int		allocd;	/* is this malloc'd? */
};

enum {
	Frepl		= 1<<0,	/* is replicated */
	Fsimple	= 1<<1,	/* is 1x1 */
	Fgrey	= 1<<2,	/* is grey */
	Falpha	= 1<<3,	/* has explicit alpha */
	Fcmap	= 1<<4,	/* has cmap channel */
	Fbytes	= 1<<5,	/* has only 8-bit channels */
};

struct Memimage
{
	Rectangle	r;		/* rectangle in data area, local coords */
	Rectangle	clipr;		/* clipping region */
	int		depth;	/* number of bits of storage per pixel */
	int		nchan;	/* number of channels */
	ulong	chan;	/* channel descriptions */
	Memcmap	*cmap;

	Memdata	*data;	/* pointer to data; shared by windows in this image */
	vlong	zero;		/* data->bdata+zero==&byte containing (0,0); vlong: an image far down its coordinates passes an int */
	ulong	width;	/* width in words of a single scan line */
	Memlayer	*layer;	/* nil if not a layer*/
	ulong	flags;

	int		shift[NChan];
	int		mask[NChan];
	int		nbits[NChan];
};

struct Memcmap
{
	uchar	cmap2rgb[3*256];
	uchar	rgb2cmap[16*16*16];
};

/*
 * Subfonts
 *
 * given char c, Subfont *f, Fontchar *i, and Point p, one says
 *	i = f->info+c;
 *	draw(b, Rect(p.x+i->left, p.y+i->top,
 *		p.x+i->left+((i+1)->x-i->x), p.y+i->bottom),
 *		color, f->bits, Pt(i->x, i->top));
 *	p.x += i->width;
 * to draw characters in the specified color (itself a Memimage) in Memimage b.
 */

struct	Memsubfont
{
	char		*name;
	short	n;		/* number of chars in font */
	uchar	height;		/* height of bitmap */
	char	ascent;		/* top of bitmap to baseline */
	Fontchar *info;		/* n+1 character descriptors */
	Memimage	*bits;		/* of font */
};

/*
 * Encapsulated parameters and information for sub-draw routines.
 */
enum {
	Simplesrc=1<<0,
	Simplemask=1<<1,
	Replsrc=1<<2,
	Replmask=1<<3,
	Fullmask=1<<4,
};
struct	Memdrawparam
{
	Memimage *dst;
	Rectangle	r;
	Memimage *src;
	Rectangle sr;
	Memimage *mask;
	Rectangle mr;
	int op;

	ulong state;
	ulong mval;	/* if Simplemask, the mask pixel in mask format */
	ulong mrgba;	/* mval in rgba */
	ulong sval;	/* if Simplesrc, the source pixel in src format */
	ulong srgba;	/* sval in rgba */
	ulong sdval;	/* sval in dst format */
};

/*
 * Memimage management
 */

extern Memimage*	allocmemimage(Rectangle, ulong);
extern Memimage*	allocmemimaged(Rectangle, ulong, Memdata*);
extern Memimage*	readmemimage(int);
extern Memimage*	creadmemimage(int);
extern int	writememimage(int, Memimage*);
extern void	freememimage(Memimage*);
extern int		loadmemimage(Memimage*, Rectangle, uchar*, int);
extern int		cloadmemimage(Memimage*, Rectangle, uchar*, int);
extern int		unloadmemimage(Memimage*, Rectangle, uchar*, int);
extern ulong*	wordaddr(Memimage*, Point);
extern uchar*	byteaddr(Memimage*, Point);
extern int		drawclip(Memimage*, Rectangle*, Memimage*, Point*, Memimage*, Point*, Rectangle*, Rectangle*);
extern void	memfillcolor(Memimage*, ulong);
extern int		memsetchan(Memimage*, ulong);

/*
 * Graphics
 */
extern void	memdraw(Memimage*, Rectangle, Memimage*, Point, Memimage*, Point, int);
extern void	memline(Memimage*, Point, Point, int, int, int, Memimage*, Point, int);
extern void	mempoly(Memimage*, Point*, int, int, int, int, Memimage*, Point, int);
extern void	memfillpoly(Memimage*, Point*, int, int, Memimage*, Point, int);
extern void	_memfillpolysc(Memimage*, Point*, int, int, Memimage*, Point, int, int, int, int);
extern void	memimagedraw(Memimage*, Rectangle, Memimage*, Point, Memimage*, Point, int);
extern int	hwdraw(Memdrawparam*);
extern void	memimageline(Memimage*, Point, Point, int, int, int, Memimage*, Point, int);
extern void	_memimageline(Memimage*, Point, Point, int, int, int, Memimage*, Point, Rectangle, int);
extern Point	memimagestring(Memimage*, Point, Memimage*, Point, Memsubfont*, char*);
extern void	memellipse(Memimage*, Point, int, int, int, Memimage*, Point, int);
extern void	memarc(Memimage*, Point, int, int, int, Memimage*, Point, int, int, int);
extern Rectangle	memlinebbox(Point, Point, int, int, int);
extern int	memlineendsize(int);
extern void	_memmkcmap(void);
extern void	memimageinit(void);

/*
 * Anti-aliased geometry (aa.c, aapath.c).
 *
 * Coordinates are fixed point, Aaone units to a pixel.  The pixel (x, y)
 * covers [x, x+1) × [y, y+1), so its centre is (x*Aaone + Aaone/2, ...).
 * A pixel's coverage is the exact area of it inside the shape, and the
 * source is drawn through that coverage as through a GREY8 mask.  It is
 * all integer arithmetic, so every platform draws the same pixels.
 *
 * An Aapath is what a client describes: subpaths of lines and curves,
 * flattened as they are added.  An Aapoly is what is rasterised: the
 * edges of closed polygons, made from a path by filling it (aafill) or
 * stroking it (aastroke).
 */
enum
{
	Aashift	= 8,		/* Pathunit in draw.h */
	Aaone	= 1<<Aashift,
	Aamaxcoord	= 1<<28,	/* |coordinate| limit, fixed point */

	/* Draw's default arrowhead (see arrow in draw-image(2)), in pixels */
	Arrow1	= 8,	/* from the end of the shaft to the tip */
	Arrow2	= 10,	/* from the barbs to the tip */
	Arrow3	= 3,	/* from the edge of the shaft to a barb */
};

typedef struct Aapath	Aapath;
typedef struct Aapoly	Aapoly;
typedef struct Aaedge	Aaedge;

struct Aapath
{
	Point	*p;		/* the points of every subpath */
	int	np;
	int	nalloc;
	int	*sub;		/* index in p of each subpath's first point */
	uchar	*closed;	/* whether each subpath was closed */
	int	nsub;
	int	nsuballoc;
	int	err;		/* out of memory, a bad coordinate, or too complex */
};

struct Aaedge
{
	int	x0, y0, x1, y1;	/* y0 < y1 */
	int	dir;		/* +1 if the edge runs down the page, -1 if up */
};

struct Aapoly
{
	Aaedge	*e;
	int	ne;
	int	nalloc;
	Rectangle	bb;	/* fixed-point bounds of the edges */
	int	err;
};

extern void	aapathinit(Aapath*);
extern void	aapathfree(Aapath*);
extern void	aamoveto(Aapath*, Point);
extern void	aalineto(Aapath*, Point);
extern void	aaquadto(Aapath*, Point, Point);
extern void	aacurveto(Aapath*, Point, Point, Point);
extern void	aaclosepath(Aapath*);
extern void	aaellipse(Aapath*, Point, int, int);
extern int	aadecode(Aapath*, uchar*, int);
extern void	aapolyinit(Aapoly*);
extern void	aapolyfree(Aapoly*);
extern void	aapolyedge(Aapoly*, Point, Point);
extern void	aafill(Aapoly*, Aapath*);
extern void	aastroke(Aapoly*, Aapath*, int, int, int, int, int);
extern void	aadrawlines(Aapoly*, Point*, int, int, int, int);
extern Rectangle	aapixels(Aapoly*);
extern void	_memaadraw(Memimage*, Aapoly*, Point, int, Memimage*, Point, Rectangle, int);
extern void	memaadraw(Memimage*, Aapoly*, int, Memimage*, Point, int);
extern char*	memfillpath(Memimage*, uchar*, int, int, Memimage*, Point, int, Rectangle*);
extern char*	memstrokepath(Memimage*, uchar*, int, int, int, int, int, Memimage*, Point, int, Rectangle*);

/*
 * Subfont management
 */
extern Memsubfont*	allocmemsubfont(char*, int, int, int, Fontchar*, Memimage*);
extern Memsubfont*	openmemsubfont(char*);
extern void	freememsubfont(Memsubfont*);
extern Point	memsubfontwidth(Memsubfont*, char*);
extern Memsubfont*	getmemdefont(void);

/*
 * Predefined 
 */
extern	Memimage*	memwhite;
extern	Memimage*	memblack;
extern	Memimage*	memopaque;
extern	Memimage*	memtransparent;
extern	Memcmap	*memdefcmap;

/*
 * Kernel interface
 */
uchar*	attachscreen(Rectangle*, ulong*, int*, int*, int*);
void		memimagemove(void*, void*);

/*
 * Kernel cruft
 */
extern void	rdb(void);
extern int		iprint(char*, ...);
#pragma varargck argpos iprint 1
extern int		drawdebug;
extern int		memdrawfast;	/* 0: no special cases, to test them */

/*
 * doprint interface: numbconv bit strings
 */
#pragma varargck type "llb" vlong
#pragma varargck type "llb" uvlong
#pragma varargck type "lb" long
#pragma varargck type "lb" ulong
#pragma varargck type "b" int
#pragma varargck type "b" uint

