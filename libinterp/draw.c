#include <lib9.h>
#include <kernel.h>
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "drawmod.h"
#include "draw.h"
#include "drawif.h"
#include "memdraw.h"
#include "memlayer.h"

/*
 * When a Display is remote, it must be locked to synchronize the
 * outgoing message buffer with the refresh demon, which runs as a
 * different process.  When it is local, the refresh demon does nothing
 * and it is sufficient to use the interpreter's own acquire/release protection
 * to lock the buffer.
 *
 * Most action to the buffer is caused by calls from Limbo, so locking at
 * the top before going into the library is good enough.  However, the
 * garbage collector can call the free routines at other times, so they
 * need to protect themselves whether called through the Draw module
 * or not; hence the need for check against recursive locking in lockdisplay().
 * This also means that we needn't lock around calls to destroy if it's
 * extra work to do so.
 */

typedef struct Cache Cache;
typedef struct DRef DRef;
typedef struct DDisplay DDisplay;
typedef struct DImage DImage;
typedef struct DScreen DScreen;
typedef struct DFont DFont;

struct Cache
{
	int	ref;
	char*	name;
	Display*display;
	union{
		Subfont*	sf;
		Font*		f;
		void*		ptr;
	}u;
	Cache*	next;
};

/* not visible to Limbo; used only for internal reference counting */
struct DRef
{
	int		ref;
	Display*	display;
};

struct DDisplay
{
	Draw_Display	drawdisplay;
	Display*	display;
	DRef*		dref;
};

struct DImage
{
	Draw_Image	drawimage;
	Image*		image;
	void*		refreshptr;
	DRef*		dref;
	int		flush;
};

struct DScreen
{
	Draw_Screen	drawscreen;
	Screen*		screen;
	DRef*		dref;
};

struct DFont
{
	Draw_Font	drawfont;
	Font*		font;
	DRef*		dref;
};

Cache*	sfcache[BIHASH];
Cache*	fcache[BIHASH];
void*	cacheqlock;

static	Cache	*cachelookup(Cache**, Display*, char*);

uchar fontmap[] = Draw_Font_map;
uchar imagemap[] = Draw_Image_map;
uchar screenmap[] = Draw_Screen_map;
uchar displaymap[] = Draw_Display_map;
uchar pathmap[] = Draw_Path_map;

Type*	TFont;
Type*	TImage;
Type*	TScreen;
Type*	TDisplay;
Type*	TPath;

static DImage*	newdimage(void);
static Draw_Image*	filldimage(DImage*, Image*, Draw_Screen*, Draw_Display*, void*);
static void	allocdrawimage(Draw_Image**, DDisplay*, Draw_Rect, ulong, int, int);
static void	color(Draw_Image**, DDisplay*, ulong);

char		deffontname[] = "*default*";
void		refreshslave(Display*);
void		subfont_close(Subfont*);
void		freeallsubfonts(Display*);

void
drawmodinit(void)
{
	TFont = dtype(freedrawfont, sizeof(DFont), fontmap, sizeof(fontmap));
	TImage = dtype(freedrawimage, sizeof(DImage), imagemap, sizeof(imagemap));
	TScreen = dtype(freedrawscreen, sizeof(DScreen), screenmap, sizeof(screenmap));
	TDisplay = dtype(freedrawdisplay, sizeof(DDisplay), displaymap, sizeof(displaymap));
	TPath = dtype(freeheap, sizeof(Draw_Path), pathmap, sizeof(pathmap));
	heapaudittype("Display", &TDisplay);
	heapaudittype("Font", &TFont);
	heapaudittype("Image", &TImage);
	heapaudittype("Screen", &TScreen);
	builtinmod("$Draw", Drawmodtab, Drawmodlen);
}

static int
drawhash(char *s)
{
	int h;

	h = 0;
	while(*s){
		h += *s++;
		h <<= 1;
		if(h & (1<<8))
			h |= 1;
	}
	return (h&0xFFFF)%BIHASH;
}

static Cache*
cachelookup(Cache *cache[], Display *d, char *name)
{
	Cache *c;

	libqlock(cacheqlock);
	c = cache[drawhash(name)];
	while(c!=nil && (d!=c->display || strcmp(name, c->name)!=0))
		c = c->next;
	libqunlock(cacheqlock);
	return c;
}

Cache*
cacheinstall(Cache **cache, Display *d, char *name, void *ptr, char *type)
{
	Cache *c;
	int hash;

	USED(type);
	c = cachelookup(cache, d, name);
	if(c){
/*		print("%s %s already in cache\n", type, name); /**/
		return nil;
	}
	c = malloc(sizeof(Cache));
	if(c == nil)
		return nil;
	hash = drawhash(name);
	c->ref = 0;	/* will be incremented by caller */
	c->display = d;
	c->name = strdup(name);
	if(c->name == nil) {
		free(c);
		return nil;
	}
	c->u.ptr = ptr;
	libqlock(cacheqlock);
	c->next = cache[hash];
	cache[hash] = c;
	libqunlock(cacheqlock);
	return c;
}

void
cacheuninstall(Cache **cache, Display *d, char *name, char *type)
{
	Cache *c, *prev;
	int hash;

	hash = drawhash(name);
	libqlock(cacheqlock);
	c = cache[hash];
	if(c == nil){
   Notfound:
		libqunlock(cacheqlock);
		print("%s not in %s cache\n", name, type);
		return;
	}
	prev = nil;
	while(c!=nil && (d!=c->display || strcmp(name, c->name)!=0)){
		prev = c;
		c = c->next;
	}
	if(c == nil)
		goto Notfound;
	if(prev == 0)
		cache[hash] = c->next;
	else
		prev->next = c->next;
	libqunlock(cacheqlock);
	free(c->name);
	free(c);
}

Image*
lookupimage(Draw_Image *di)
{
	Display *disp;
	Image *i;
	int locked;

	if(di == H || D2H(di)->t != TImage)
		return nil;
	i = ((DImage*)di)->image;
	if(i == nil)
		return nil;
	if(!eqrect(IRECT(di->clipr), i->clipr) || di->repl!=i->repl){
		disp = i->display;
		locked = lockdisplay(disp);
		replclipr(i, di->repl, IRECT(di->clipr));
		if(locked)
			unlockdisplay(disp);
	}
	return i;
}

Screen*
lookupscreen(Draw_Screen *ds)
{
	if(ds == H || D2H(ds)->t != TScreen)
		return nil;
	return ((DScreen*)ds)->screen;
}

Font*
lookupfont(Draw_Font *df)
{
	if(df == H || D2H(df)->t != TFont)
		return nil;
	return ((DFont*)df)->font;
}

Display*
lookupdisplay(Draw_Display *dd)
{
	if(dd == H || D2H(dd)->t != TDisplay)
		return nil;
	return ((DDisplay*)dd)->display;
}

Image*
checkimage(Draw_Image *di)
{
	Image *i;

	if(di == H)
		error("nil Image");
	i = lookupimage(di);
	if(i == nil)
		error(exType);
	return i;
}

Screen*
checkscreen(Draw_Screen *ds)
{
	Screen *s;

	if(ds == H)
		error("nil Screen");
	s = lookupscreen(ds);
	if(s == nil)
		error(exType);
	return s;
}

Font*
checkfont(Draw_Font *df)
{
	Font *f;

	if(df == H)
		error("nil Font");
	f = lookupfont(df);
	if(f == nil)
		error(exType);
	return f;
}

Display*
checkdisplay(Draw_Display *dd)
{
	Display *d;

	if(dd == H)
		error("nil Display");
	d = lookupdisplay(dd);
	if(d == nil)
		error(exType);
	return d;
}

void
Display_allocate(void *fp)
{
	F_Display_allocate *f;
	char buf[128], *dev;
	Subfont *df;
	Display *display;
	DDisplay *dd;
	DImage *di[5];
	Heap *h;
	DRef *dr;
	Cache *c;
	int i;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	if(cacheqlock == nil){
		cacheqlock = libqlalloc();
		if(cacheqlock == nil)
			return;
	}
	dev = string2c(f->dev);
	if(dev[0] == 0)
		dev = 0;

	/*
	 * The Display's cell and its five images' first: heap() raises
	 * when the heap is full, and initdisplay returns holding the
	 * display's lock.  They were made after it, so a full heap left
	 * the program a Display whose lock nobody would ever release,
	 * which closedisplay then waited for in whoever freed it.  All
	 * six before the result is set: one refused leaves those before
	 * it to the collector (a cell with nothing in it frees as
	 * nothing), and the caller with no Display, not half of one.
	 */
	h = heap(TDisplay);
	dd = H2D(DDisplay*, h);
	for(i = 0; i < nelem(di); i++)
		di[i] = newdimage();
	*f->ret = &dd->drawdisplay;
	dd->drawdisplay.image = &di[0]->drawimage;
	dd->drawdisplay.black = &di[1]->drawimage;
	dd->drawdisplay.white = &di[2]->drawimage;
	dd->drawdisplay.opaque = &di[3]->drawimage;
	dd->drawdisplay.transparent = &di[4]->drawimage;

	dr = malloc(sizeof(DRef));
	display = nil;
	if(dr != nil)
		display = initdisplay(dev, dev, nil);	/* TO DO: win, error */
	if(display == nil){
		free(dr);
		*f->ret = H;
		destroy(&dd->drawdisplay);
		return;
	}
	dd->display = display;
	dd->dref = dr;
	display->limbo = dr;
	dr->display = display;
	dr->ref = 1;
	df = getdefont(display);
	if(df){
		display->defaultsubfont = df;
		sprint(buf, "%d %d\n0 %d\t%s\n", df->height, df->ascent,
			df->n-1, deffontname);
		display->defaultfont = buildfont(display, buf, deffontname);
		if(display->defaultfont){
			c = cacheinstall(fcache, display, deffontname, display->defaultfont, "font");
			if(c)
				c->ref++;
			/* else BUG? */
		}
	}

	filldimage(di[0], display->image, H, &dd->drawdisplay, nil);
	filldimage(di[1], display->black, H, &dd->drawdisplay, nil);
	filldimage(di[2], display->white, H, &dd->drawdisplay, nil);
	filldimage(di[3], display->opaque, H, &dd->drawdisplay, nil);
	filldimage(di[4], display->transparent, H, &dd->drawdisplay, nil);

	/* don't call unlockdisplay because the qlock was left up by initdisplay */
	libqunlock(display->qlock);
}

void
Display_getwindow(void *fp)
{
	F_Display_getwindow *f;
	Display *disp;
	DDisplay *dd;
	DScreen *ds;
	DImage *di, *dsi;
	int locked, n;
	Image *image;
	Screen *screen;
	char *wn;
	void *r;

	f = fp;
	r = f->ret->t0;
	f->ret->t0 = H;
	destroy(r);
	r = f->ret->t1;
	f->ret->t1 = H;
	destroy(r);
	disp = checkdisplay(f->d);
	dd = (DDisplay*)f->d;
	/*
	 * Given a Screen and Image to attach again, gengetwindow frees
	 * what they hold and makes others; the two given were handed
	 * back still holding what had been freed, and using or dropping
	 * them used it again.  Nothing asks for that form: it is refused.
	 */
	if(f->image != H || f->screen != H)
		error(exInval);
	if(f->winname == H)
		wn = "/dev/winname";
	else
		wn = string2c(f->winname);

	/*
	 * The cells first: heap() raises when the heap is full, and did
	 * with the display locked.  All three before the result is set,
	 * as Display_allocate.
	 */
	ds = H2D(DScreen*, heap(TScreen));
	dsi = newdimage();
	di = newdimage();
	f->ret->t0 = &ds->drawscreen;
	ds->drawscreen.image = &dsi->drawimage;
	f->ret->t1 = &di->drawimage;

	image = nil;
	screen = nil;
	locked = lockdisplay(disp);
	n = gengetwindow(disp, wn, &image, &screen, f->backup);
	if(n < 0 && screen != nil){
		/* a screen was made and the window on it was not */
		freeimage(screen->image);
		freescreen(screen);
		screen = nil;
	}
	if(locked)
		unlockdisplay(disp);

	if(n < 0 || image == nil || screen == nil){
		f->ret->t0 = H;
		f->ret->t1 = H;
		destroy(&ds->drawscreen);
		destroy(&di->drawimage);
		/*
		 * With no window to name, the image is the display's own.
		 * It was given a second Draw->Image, and dropping that one
		 * freed the image under the Display, which freed it again.
		 */
		if(n >= 0 && image != nil && image == disp->image && dd->drawdisplay.image != H){
			f->ret->t1 = dd->drawdisplay.image;
			D2H(f->ret->t1)->ref++;
		}
		return;
	}

	/*
	 * The screen is filled with the display's white, which is the
	 * Display's to free: its own Draw->Image, not another on it.
	 */
	filldimage(dsi, screen->image, H, f->d, nil);
	ds->screen = screen;
	if(screen->fill == disp->white && dd->drawdisplay.white != H){
		ds->drawscreen.fill = dd->drawdisplay.white;
		D2H(ds->drawscreen.fill)->ref++;
	}
	ds->drawscreen.display = f->d;
	D2H(f->d)->ref++;
	ds->drawscreen.id = screen->id;
	ds->dref = disp->limbo;
	ds->dref->ref++;
	filldimage(di, image, &ds->drawscreen, f->d, nil);
}

void
Display_startrefresh(void *fp)
{
	F_Display_startrefresh *f;
	Display *disp;

	f = fp;
	disp = checkdisplay(f->d);
	refreshslave(disp);
}

void
display_dec(void *v)
{
	DRef *dr;
	Display *d;
	int locked;

	dr = v;
	if(dr->ref-- != 1)
		return;

	d = dr->display;
	locked = lockdisplay(d);
	/*
	 * A display made when there was no room for the default font's
	 * image has neither; closing the nil one faulted, and this is
	 * most often the collector's sweep, where a fault ends emu.
	 */
	if(d->defaultfont != nil)
		font_close(d->defaultfont);
	if(d->defaultsubfont != nil)
		subfont_close(d->defaultsubfont);
	if(locked)
		unlockdisplay(d);
	freeallsubfonts(d);
	closedisplay(d);
	free(dr);
}

void
freedrawdisplay(Heap *h, int swept)
{
	DDisplay *dd;
	Display *d;

	dd = H2D(DDisplay*, h);

	if(!swept) {
		destroy(dd->drawdisplay.image);
		destroy(dd->drawdisplay.black);
		destroy(dd->drawdisplay.white);
		destroy(dd->drawdisplay.opaque);
		destroy(dd->drawdisplay.transparent);
	}
	/* we've now released dd->image etc.; make sure they're not freed again */
	d = dd->display;
	if(d == nil)	/* Display_allocate did not get as far as a display */
		return;
	d->image = nil;
	d->white = nil;
	d->black = nil;
	d->opaque = nil;
	d->transparent = nil;
	display_dec(dd->dref);
	/* Draw_Display header will be freed by caller */
}

void
Display_color(void *fp)
{
	F_Display_color *f;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	checkdisplay(f->d);
	color(f->ret, (DDisplay*)f->d, f->color);
}

void
Image_flush(void *fp)
{
	F_Image_flush *f;
	Image *d;
	DImage *di;
	int locked;

	f = fp;
	d = checkimage(f->win);
	di = (DImage*)f->win;
	switch(f->func){
	case 0:	/* Draw->Flushoff */
		di->flush = 0;
		break;
	case 1:	/* Draw->Flushon */
		di->flush = 1;
		/* fall through */
	case 2:	/* Draw->Flushnow */
		locked = lockdisplay(d->display);
		if(d->id==0 || d->screen!=0)
			flushimage(d->display, 1);
		if(locked)
			unlockdisplay(d->display);
		break;
	default:
		error(exInval);
	}
}

void
checkflush(Draw_Image *dst)
{
	DImage  *di;

	di = (DImage*)dst;
	if(di->flush && (di->image->id==0 || di->image->screen!=nil))
		flushimage(di->image->display, 1);
}

static void
imagedraw(void *fp, int op)
{
	F_Image_draw *f;
	Image *d, *s, *m;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	if(f->src == H)
		s = d->display->black;
	else
		s = checkimage(f->src);
	if(f->matte == H)
		m = d->display->white;	/* ones */
	else
		m = checkimage(f->matte);
	if(d->display!=s->display || d->display!=m->display)
		return;
	locked = lockdisplay(d->display);
	drawop(d, IRECT(f->r), s, m, IPOINT(f->p), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_draw(void *fp)
{
	imagedraw(fp, SoverD);
}

void
Image_drawop(void *fp)
{
	F_Image_drawop *f;

	f = fp;
	imagedraw(fp, f->op);
}

static void
imagegendraw(void *fp, int op)
{
	F_Image_gendraw *f;
	Image *d, *s, *m;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	if(f->src == H)
		s = d->display->black;
	else
		s = checkimage(f->src);
	if(f->matte == H)
		m = d->display->white;	/* ones */
	else
		m = checkimage(f->matte);
	if(d->display!=s->display || d->display!=m->display)
		return;
	locked = lockdisplay(d->display);
	gendrawop(d, IRECT(f->r), s, IPOINT(f->p0), m, IPOINT(f->p1), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_gendraw(void *fp)
{
	imagegendraw(fp, SoverD);
}

void
Image_gendrawop(void *fp)
{
	F_Image_gendrawop *f;

	f = fp;
	imagegendraw(fp, f->op);
}

static void
drawline(void *fp, int op)
{
	F_Image_line *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display || f->radius < 0)
		return;
	locked = lockdisplay(d->display);
	lineop(d, IPOINT(f->p0), IPOINT(f->p1), f->end0, f->end1, f->radius, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_line(void *fp)
{
	drawline(fp, SoverD);
}

void
Image_lineop(void *fp)
{
	F_Image_lineop *f;

	f = fp;
	drawline(fp, f->op);
}

/*
 * Convert Draw_Point array (WORD-sized coords) to C Point array (int-sized).
 * On LP64, Draw_Point is 16 bytes (two 8-byte WORDs), while Point is 8 bytes
 * (two 4-byte ints).  The old "sleazy" cast (Point*)data only works on
 * 32-bit systems where WORD == int.
 */
static Point*
cvtpoints(Draw_Point *dp, int n)
{
	Point *pp;
	int i;

	pp = malloc(n * sizeof(Point));
	if(pp == nil)
		return nil;
	for(i = 0; i < n; i++){
		pp[i].x = (int)dp[i].x;
		pp[i].y = (int)dp[i].y;
	}
	return pp;
}

static void
drawsplinepoly(void *fp, int smooth, int op)
{
	F_Image_poly *f;
	Image *d, *s;
	Point *pp;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(f->p == H)
		error(exNilref);
	if(d->display != s->display|| f->radius < 0)
		return;
	pp = cvtpoints((Draw_Point*)f->p->data, f->p->len);
	if(pp == nil)
		return;
	locked = lockdisplay(d->display);
	if(smooth)
		bezsplineop(d, pp, f->p->len,
			f->end0, f->end1, f->radius, s, IPOINT(f->sp), op);
	else
		polyop(d, pp, f->p->len, f->end0,
			f->end1, f->radius, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
	free(pp);
}

void
Image_poly(void *fp)
{
	drawsplinepoly(fp, 0, SoverD);
}

void
Image_polyop(void *fp)
{
	F_Image_polyop *f;

	f = fp;
	drawsplinepoly(fp, 0, f->op);
}

void
Image_bezspline(void *fp)
{
	drawsplinepoly(fp, 1, SoverD);
}

void
Image_bezsplineop(void *fp)
{
	F_Image_bezsplineop *f;

	f = fp;
	drawsplinepoly(fp, 1, f->op);
}

static void
drawbezier(void *fp, int op)
{
	F_Image_bezier *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display || f->radius < 0)
		return;
	locked = lockdisplay(d->display);
	bezierop(d, IPOINT(f->a), IPOINT(f->b), IPOINT(f->c),
		  IPOINT(f->d), f->end0, f->end1, f->radius, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_bezier(void *fp)
{
	drawbezier(fp, SoverD);
}

void
Image_bezierop(void *fp)
{
	F_Image_bezierop *f;

	f = fp;
	drawbezier(fp, f->op);
}

static void
drawfillbezier(void *fp, int op)
{
	F_Image_fillbezier *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display)
		return;
	locked = lockdisplay(d->display);
	fillbezierop(d, IPOINT(f->a), IPOINT(f->b), IPOINT(f->c),
			IPOINT(f->d), f->wind, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_fillbezier(void *fp)
{
	drawfillbezier(fp, SoverD);
}

void
Image_fillbezierop(void *fp)
{
	F_Image_fillbezierop *f;

	f = fp;
	drawfillbezier(fp, f->op);
}

static void
drawfillsplinepoly(void *fp, int smooth, int op)
{
	F_Image_fillpoly *f;
	Image *d, *s;
	Point *pp;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(f->p == H)
		error(exNilref);
	if(d->display != s->display)
		return;
	pp = cvtpoints((Draw_Point*)f->p->data, f->p->len);
	if(pp == nil)
		return;
	locked = lockdisplay(d->display);
	if(smooth)
		fillbezsplineop(d, pp, f->p->len,
			f->wind, s, IPOINT(f->sp), op);
	else
		fillpolyop(d, pp, f->p->len,
			f->wind, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
	free(pp);
}

void
Image_fillpoly(void *fp)
{
	drawfillsplinepoly(fp, 0, SoverD);
}

void
Image_fillpolyop(void *fp)
{
	F_Image_fillpolyop *f;

	f = fp;
	drawfillsplinepoly(fp, 0, f->op);
}

void
Image_fillbezspline(void *fp)
{
	drawfillsplinepoly(fp, 1, SoverD);
}

void
Image_fillbezsplineop(void *fp)
{
	F_Image_fillbezsplineop *f;

	f = fp;
	drawfillsplinepoly(fp, 1, f->op);
}

/*
 * Paths: built in real pixel coordinates, kept encoded as the draw
 * device takes them (libdraw/path.c), and filled or stroked there.
 */
static int
fixcoord(REAL v)
{
	v *= Pathunit;
	if(v != v || v >= (1<<28) || v <= -(1<<28))
		error("path coordinate out of range");
	if(v < 0)
		return -(int)(-v + 0.5);
	return (int)(v + 0.5);
}

static void
pathadd(Draw_Path *p, int verb, REAL *v, int nv)
{
	uchar buf[64];
	Point q[3], last;
	Heap *h;
	Array *a;
	int i, n, len;

	if(p == H)
		error(exNilref);
	for(i = 0; i < nv/2; i++)
		q[i] = Pt(fixcoord(v[2*i]), fixcoord(v[2*i+1]));
	if(verb == 'E' && (q[1].x < 0 || q[1].y < 0))
		error("negative ellipse semi-axis");
	last = Pt(p->x, p->y);
	n = _pathverb(buf, &last, verb, q, verb == 'E' ? 1 : nv/2);
	len = 0;
	if(p->data != H)
		len = p->data->len;
	if(p->n < 0 || p->n > len)
		error(exBounds);
	if(p->n + n > len){
		len = 2*len + n;
		if(len < 64)
			len = 64;
		h = heaparray(&Tbyte, len);
		a = H2D(Array*, h);
		if(p->data != H){
			memmove(a->data, p->data->data, p->n);
			destroy(p->data);
		}
		p->data = a;
	}
	memmove(p->data->data + p->n, buf, n);
	p->n += n;
	p->x = last.x;
	p->y = last.y;
}

/* the methods return the path, so calls can be chained */
static void
pathret(Draw_Path **ret, Draw_Path *p)
{
	Heap *h;

	h = D2H(p);
	h->ref++;
	Setmark(h);
	destroy(*ret);
	*ret = p;
}

void
Path_new(void *fp)
{
	F_Path_new *f;
	Heap *h;
	Draw_Path *p;

	f = fp;
	h = heap(TPath);
	p = H2D(Draw_Path*, h);
	p->data = H;
	p->n = 0;
	p->x = 0;
	p->y = 0;
	destroy(*f->ret);
	*f->ret = p;
}

void
Path_moveto(void *fp)
{
	F_Path_moveto *f;
	REAL v[2];

	f = fp;
	v[0] = f->x;
	v[1] = f->y;
	pathadd(f->p, 'M', v, 2);
	pathret(f->ret, f->p);
}

void
Path_lineto(void *fp)
{
	F_Path_lineto *f;
	REAL v[2];

	f = fp;
	v[0] = f->x;
	v[1] = f->y;
	pathadd(f->p, 'L', v, 2);
	pathret(f->ret, f->p);
}

void
Path_quadto(void *fp)
{
	F_Path_quadto *f;
	REAL v[4];

	f = fp;
	v[0] = f->x1;
	v[1] = f->y1;
	v[2] = f->x;
	v[3] = f->y;
	pathadd(f->p, 'Q', v, 4);
	pathret(f->ret, f->p);
}

void
Path_curveto(void *fp)
{
	F_Path_curveto *f;
	REAL v[6];

	f = fp;
	v[0] = f->x1;
	v[1] = f->y1;
	v[2] = f->x2;
	v[3] = f->y2;
	v[4] = f->x;
	v[5] = f->y;
	pathadd(f->p, 'C', v, 6);
	pathret(f->ret, f->p);
}

void
Path_ellipse(void *fp)
{
	F_Path_ellipse *f;
	REAL v[4];

	f = fp;
	v[0] = f->cx;
	v[1] = f->cy;
	v[2] = f->a;
	v[3] = f->b;
	pathadd(f->p, 'E', v, 4);
	pathret(f->ret, f->p);
}

void
Path_close(void *fp)
{
	F_Path_close *f;

	f = fp;
	pathadd(f->p, 'Z', nil, 0);
	pathret(f->ret, f->p);
}

static void
drawpath(Draw_Image *dst, Draw_Path *p, int stroke, int wind, REAL width, int cap, int join, Draw_Image *src, Draw_Point sp, int op)
{
	Image *d, *s;
	int locked, w;

	d = checkimage(dst);
	s = checkimage(src);
	if(p == H || p->data == H || p->n <= 0)
		return;
	if(p->n > p->data->len)
		error(exBounds);
	if(d->display != s->display)
		return;
	/*
	 * fixcoord raises for a width out of range: before the display
	 * is locked, not after, when the lock was left held for good.
	 */
	w = 0;
	if(stroke)
		w = fixcoord(width);
	locked = lockdisplay(d->display);
	if(stroke)
		_strokepath(d, p->data->data, p->n, w, cap, join, 4*Pathunit, s, IPOINT(sp), op);
	else
		_fillpath(d, p->data->data, p->n, wind, s, IPOINT(sp), op);
	checkflush(dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_fillpath(void *fp)
{
	F_Image_fillpath *f;

	f = fp;
	drawpath(f->dst, f->p, 0, f->wind, 0, 0, 0, f->src, f->sp, SoverD);
}

void
Image_fillpathop(void *fp)
{
	F_Image_fillpathop *f;

	f = fp;
	drawpath(f->dst, f->p, 0, f->wind, 0, 0, 0, f->src, f->sp, f->op);
}

void
Image_strokepath(void *fp)
{
	F_Image_strokepath *f;

	f = fp;
	drawpath(f->dst, f->p, 1, 0, f->width, f->cap, f->join, f->src, f->sp, SoverD);
}

void
Image_strokepathop(void *fp)
{
	F_Image_strokepathop *f;

	f = fp;
	drawpath(f->dst, f->p, 1, 0, f->width, f->cap, f->join, f->src, f->sp, f->op);
}

static void
drawarcellipse(void *fp, int isarc, int alpha, int phi, int op)
{
	F_Image_arc *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display || f->thick < 0 || f->a<0 || f->b<0)
		return;

	locked = lockdisplay(d->display);
	if(isarc)
		arcop(d, IPOINT(f->c), f->a, f->b, f->thick, s,
			IPOINT(f->sp), alpha, phi, op);
	else
		ellipseop(d, IPOINT(f->c), f->a, f->b, f->thick, s,
			IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_ellipse(void *fp)
{
	drawarcellipse(fp, 0, 0, 0, SoverD);
}

void
Image_ellipseop(void *fp)
{
	F_Image_ellipseop *f;

	f = fp;
	drawarcellipse(fp, 0, 0, 0, f->op);
}

void
Image_arc(void *fp)
{
	F_Image_arc *f;

	f = fp;
	drawarcellipse(fp, 1, f->alpha, f->phi, SoverD);
}

void
Image_arcop(void *fp)
{
	F_Image_arcop *f;

	f = fp;
	drawarcellipse(fp, 1, f->alpha, f->phi, f->op);
}

static void
drawfillarcellipse(void *fp, int isarc, int alpha, int phi, int op)
{
	F_Image_fillarc *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display || f->a<0 || f->b<0)
		return;

	locked = lockdisplay(d->display);
	if(isarc)
		fillarcop(d, IPOINT(f->c), f->a, f->b, s, IPOINT(f->sp), alpha, phi, op);
	else
		fillellipseop(d, IPOINT(f->c), f->a, f->b, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_fillellipse(void *fp)
{
	drawfillarcellipse(fp, 0, 0, 0, SoverD);
}

void
Image_fillellipseop(void *fp)
{
	F_Image_fillellipseop *f;

	f = fp;
	drawfillarcellipse(fp, 0, 0, 0, f->op);
}

void
Image_fillarc(void *fp)
{
	F_Image_fillarc *f;

	f = fp;
	drawfillarcellipse(fp, 1, f->alpha, f->phi, SoverD);
}

void
Image_fillarcop(void *fp)
{
	F_Image_fillarcop *f;

	f = fp;
	drawfillarcellipse(fp, 1, f->alpha, f->phi, f->op);
}

static void
drawtext(void *fp, int op)
{
	F_Image_text *f;
	Font *font;
	Point pt;
	Image *s, *d;
	String *str;
	int locked;

	f = fp;
	/*
	 * Where nothing is drawn the text ends where it began: the
	 * result was whatever the C stack held, an address among it.
	 */
	pt = IPOINT(f->p);
	if(f->dst == H || f->src == H)
		goto Return;
	if(f->font == H || f->str == H)
		goto Return;
	str = f->str;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	font = checkfont(f->font);
	if(d->display!=s->display || d->display!=font->display)
		goto Return;
	locked = lockdisplay(d->display);
	if(str->len >= 0)
		pt = stringnop(d, IPOINT(f->p), s, IPOINT(f->sp), font, str->Sascii, str->len, op);
	else
		pt = runestringnop(d, IPOINT(f->p), s, IPOINT(f->sp), font, str->Srune, -str->len, op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
    Return:
	P2P(*f->ret, pt);
}

void
Image_text(void *fp)
{
	drawtext(fp, SoverD);
}

void
Image_textop(void *fp)
{
	F_Image_textop *f;

	f = fp;
	drawtext(fp, f->op);
}

static void
drawtextbg(void *fp, int op)
{
	F_Image_textbg *f;
	Font *font;
	Point pt;
	Image *s, *d, *bg;
	String *str;
	int locked;

	f = fp;
	pt = IPOINT(f->p);	/* as drawtext */
	if(f->dst == H || f->src == H)
		goto Return;
	if(f->font == H || f->str == H)
		goto Return;
	str = f->str;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	bg = checkimage(f->bg);
	font = checkfont(f->font);
	/* bg too: its id was sent to dst's display, where it is another image's */
	if(d->display!=s->display || d->display!=font->display || d->display!=bg->display)
		goto Return;
	locked = lockdisplay(d->display);
	if(str->len >= 0)
		pt = stringnbgop(d, IPOINT(f->p), s, IPOINT(f->sp), font, str->Sascii, str->len, bg, IPOINT(f->bgp), op);
	else
		pt = runestringnbgop(d, IPOINT(f->p), s, IPOINT(f->sp), font, str->Srune, -str->len, bg, IPOINT(f->bgp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
    Return:
	P2P(*f->ret, pt);
}

void
Image_textbg(void *fp)
{
	drawtextbg(fp, SoverD);
}

void
Image_textbgop(void *fp)
{
	F_Image_textbgop *f;

	f = fp;
	drawtextbg(fp, f->op);
}

static void
drawborder(void *fp, int op)
{
	F_Image_border *f;
	Image *d, *s;
	int locked;

	f = fp;
	d = checkimage(f->dst);
	s = checkimage(f->src);
	if(d->display != s->display)
		return;
	locked = lockdisplay(d->display);
	borderop(d, IRECT(f->r), f->i, s, IPOINT(f->sp), op);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(d->display);
}

void
Image_border(void *fp)
{
	drawborder(fp, SoverD);
}

void
Display_newimage(void *fp)
{
	F_Display_newimage *f;

	f = fp;
	checkdisplay(f->d);
	destroy(*f->ret);
	*f->ret = H;
	allocdrawimage(f->ret, (DDisplay*)f->d, f->r, f->chans.desc, f->repl, f->color);
	if(*f->ret == H){
		char err[ERRMAX];
		Image *si;	/* the display's screen image: an Image, not a Memimage, so chan is read from the right place */

		err[0] = 0;
		kgerrstr(err, sizeof err);
		si = ((DDisplay*)f->d)->display->image;
		print("Display_newimage FAIL: r=(%d,%d)-(%d,%d) chan=%.8lux repl=%d color=%#ux screenchan=%.8lux: %s\n",
			f->r.min.x, f->r.min.y, f->r.max.x, f->r.max.y,
			f->chans.desc, f->repl, f->color,
			si != nil ? si->chan : 0, err);
	}
}

void
Display_colormix(void *fp)
{
	F_Display_colormix *f;
	Display *disp;
	Image *i;
	DImage *di;
	int locked;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	disp = checkdisplay(f->d);
	di = newdimage();	/* before the image, which would be lost if this raised */
	*f->ret = &di->drawimage;
	locked = lockdisplay(disp);
	i = allocimagemix(disp, f->c1, f->c2);
	if(locked)
		unlockdisplay(disp);
	if(i == nil){		/* the display has gone: a remote one hung up, say */
		*f->ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, i, H, f->d, nil);
}

void
Image_readpixels(void *fp)
{
	F_Image_readpixels *f;
	Rectangle r;
	Image *i;
	int locked;

	f = fp;
	R2R(r, f->r);
	i = checkimage(f->src);
	if(f->data == H)
		error(exNilref);
	locked = lockdisplay(i->display);
	*f->ret = unloadimage(i, r, f->data->data, f->data->len);
	if(locked)
		unlockdisplay(i->display);
}

void
Image_writepixels(void *fp)
{
	Rectangle r;
	F_Image_writepixels *f;
	Image *i;
	int locked;

	f = fp;
	R2R(r, f->r);
	i = checkimage(f->dst);
	if(f->data == H)
		error(exNilref);
	locked = lockdisplay(i->display);
	*f->ret = loadimage(i, r, f->data->data, f->data->len);
	checkflush(f->dst);
	if(locked)
		unlockdisplay(i->display);
}

void
Image_arrow(void *fp)
{
	F_Image_arrow *f;

	f = fp;
	*f->ret = ARROW(f->a, f->b, f->c);
}

void
Image_name(void *fp)
{
	F_Image_name *f;
	Image *i;
	int locked, ok;
	char *name;

	f = fp;
	*f->ret = -1;
	i = checkimage(f->src);
	name = string2c(f->name);
	locked = lockdisplay(i->display);
	*f->ret = ok = nameimage(i, name, f->in);
	if(locked)
		unlockdisplay(i->display);
	if(ok){
		destroy(f->src->iname);
		if(f->in){
			f->src->iname = f->name;
			D2H(f->name)->ref++;
		}else
			f->src->iname = H;
	}
}

Image*
display_open(Display *disp, char *name)
{
	Image *i;
	int fd;

	fd = libopen(name, OREAD);
	if(fd < 0)
		return nil;

	i = readimage(disp, fd, 1);
	libclose(fd);
	return i;
}

void
Display_open(void *fp)
{
	Image *i;
	DImage *di;
	Display *disp;
	F_Display_open *f;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	disp = lookupdisplay(f->d);
	if(disp == nil)
		return;
	di = newdimage();	/* before the image, which would be lost if this raised */
	*f->ret = &di->drawimage;
	i = display_open(disp, string2c(f->name));
	if(i == nil){
		*f->ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, i, H, f->d, nil);
}

void
Display_namedimage(void *fp)
{
	F_Display_namedimage *f;
	Display *d;
	Image *i;
	DImage *di;
	char *name;
	int locked;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	d = checkdisplay(f->d);
	name = string2c(f->name);	/* which may raise: before the lock */
	di = newdimage();	/* before the image, which would be lost if this raised */
	*f->ret = &di->drawimage;
	locked = lockdisplay(d);
	i = namedimage(d, name);
	if(locked)
		unlockdisplay(d);
	if(i == nil){
		*f->ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, i, H, f->d, nil);
	if(f->name != H){
		di->drawimage.iname = f->name;
		D2H(f->name)->ref++;
	}
}

void
Display_readimage(void *fp)
{
	Image *i;
	DImage *di;
	Display *disp;
	F_Display_readimage *f;
	Sys_FD *fd;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	fd = f->fd;
	if(fd == H)
		return;
	disp = checkdisplay(f->d);
	di = newdimage();	/* before the image, which would be lost if this raised */
	*f->ret = &di->drawimage;
	i = readimage(disp, fd->fd, 1);
	if(i == nil){
		*f->ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, i, H, f->d, nil);
}

void
Display_writeimage(void *fp)
{
	Image *i;
	F_Display_writeimage *f;
	Sys_FD *fd;

	f = fp;
	*f->ret = -1;
	fd = f->fd;
	if(fd == H)
		return;
	i = checkimage(f->i);
	if(checkdisplay(f->d) != i->display)
		return;
	*f->ret = writeimage(fd->fd, i, 1);	/* TO DO: dolock? */
}

void
Screen_allocate(void *fp)
{
	F_Screen_allocate *f;
	DScreen *ds;
	Screen *s;
	Image *image, *fill;
	int locked;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	image = checkimage(f->image);
	fill = checkimage(f->fill);
	/*
	 * The cell before the screen: heap() raises when the heap is
	 * full, and did so after the screen was made, with the display
	 * locked.
	 */
	ds = H2D(DScreen*, heap(TScreen));
	*f->ret = &ds->drawscreen;
	locked = lockdisplay(image->display);
	s = allocscreen(image, fill, f->public);
	if(locked)
		unlockdisplay(image->display);
	if(s == nil){
		*f->ret = H;
		destroy(&ds->drawscreen);
		return;
	}
	ds->screen = s;
	ds->drawscreen.fill = f->fill;
	D2H(f->fill)->ref++;
	ds->drawscreen.image = f->image;
	D2H(f->image)->ref++;
	ds->drawscreen.display = f->image->display;
	D2H(f->image->display)->ref++;
	ds->drawscreen.id = s->id;
	ds->dref = image->display->limbo;
	ds->dref->ref++;
}

void
Display_publicscreen(void *fp)
{
	F_Display_publicscreen *f;
	Heap *h;
	Screen *s;
	DScreen *ds;
	Display *disp;
	int locked;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	disp = checkdisplay(f->d);
	h = heap(TScreen);	/* before the screen, as Screen_allocate */
	ds = H2D(DScreen*, h);
	*f->ret = &ds->drawscreen;
	locked = lockdisplay(disp);
	s = publicscreen(disp, f->id, disp->image->chan);
	if(locked)
		unlockdisplay(disp);
	if(s == nil){
		*f->ret = H;
		destroy(&ds->drawscreen);
		return;
	}
	ds->screen = s;
	ds->drawscreen.fill = H;
	ds->drawscreen.image =H;
	ds->drawscreen.id = s->id;
	ds->drawscreen.display = f->d;
	D2H(f->d)->ref++;
	ds->dref = disp->limbo;
	ds->dref->ref++;
}

void
freedrawscreen(Heap *h, int swept)
{
	DScreen *ds;
	Screen *s;
	Display *disp;
	int locked;

	ds = H2D(DScreen*, h);
	if(!swept) {
		destroy(ds->drawscreen.image);
		destroy(ds->drawscreen.fill);
		destroy(ds->drawscreen.display);
	}
	s = lookupscreen(&ds->drawscreen);
	if(s == nil)	/* a cell no screen was put in; its pointers went above */
		return;
	disp = s->display;
	locked = lockdisplay(disp);
	freescreen(s);
	if(locked)
		unlockdisplay(disp);
	display_dec(ds->dref);
	/* screen header will be freed by caller */
}

/*
 * A Draw->Font's cell, made before the font it is to hold: heap()
 * raises when the heap is full, and a font opened by then was lost.
 */
static DFont*
newdfont(void)
{
	return H2D(DFont*, heap(TFont));
}

static void
filldfont(DFont *dfont, Font *font, String *name, Draw_Display *d, Display *disp)
{
	dfont->font = font;
	dfont->drawfont.name = name;
	if(name != H)	/* a font may be built with no name: nil is the empty string */
		D2H(name)->ref++;
	dfont->drawfont.height = font->height;
	dfont->drawfont.ascent = font->ascent;
	dfont->drawfont.display = d;
	D2H(d)->ref++;
	dfont->dref = disp->limbo;
	dfont->dref->ref++;
}

void
Font_build(void *fp)
{
	F_Font_build *f;
	Font *font;
	DFont *dfont;
	char buf[128];
	char *name, *data, *desc;
	Subfont *df;
	Display *disp;
	int locked;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	disp = checkdisplay(f->d);

	dfont = newdfont();
	*f->ret = &dfont->drawfont;
	name = string2c(f->name);
	font = font_open(disp, name);
	if(font == nil) {
		data = nil;
		desc = nil;
		if(strcmp(name, deffontname) == 0) {
			/* a display made with no room for the default font has none */
			df = disp->defaultsubfont;
			if(df != nil){
				snprint(buf, sizeof buf, "%d %d\n0 %d\t%s\n",
					df->height, df->ascent, df->n-1, name);
				data = buf;
			}
		}
		else
		if(f->desc != H){
			/*
			 * buildfont cuts its description up in place, and
			 * string2c gives the caller's own String: a copy.
			 */
			desc = strdup(string2c(f->desc));
			data = desc;
		}

		if(data != nil){
			locked = lockdisplay(disp);
			font = buildfont(disp, data, name);
			if(locked)
				unlockdisplay(disp);
		}
		free(desc);
		if(font == nil){
			*f->ret = H;
			destroy(&dfont->drawfont);
			return;
		}
	}
	filldfont(dfont, font, f->name, f->d, disp);
}

Font*
font_open(Display *display, char *name)
{
	Cache *c;
	Font *font;
	int locked;

	c = cachelookup(fcache, display, name);
	if(c)
		font = c->u.f;
	else {
		locked = lockdisplay(display);
		font = openfont(display, name);
		if(locked)
			unlockdisplay(display);
		if(font == nil)
			return nil;
		c = cacheinstall(fcache, display, name, font, "font");
	}
	if(c)
		c->ref++;

	return font;
}

void
font_close(Font *f)
{
	Cache *c;
	Display *disp;
	int locked;
	disp = f->display;
	if(f->name == nil)
		return;

	/* fonts from Font_build() aren't always in fcache, but we still need to free them */
	c = cachelookup(fcache, disp, f->name);
	if(c != nil && f == c->u.f) {
		if(c->ref <= 0)
			return;
		if(c->ref-- != 1)
			return;
		cacheuninstall(fcache, disp, f->name, "font");
	}

	locked = lockdisplay(disp);
	freefont(f);
	if(locked)
		unlockdisplay(disp);
}

void
freecachedsubfont(Subfont *sf)
{
	Cache *c;
	Display *disp;

	disp = sf->bits->display;
	c = cachelookup(sfcache, disp, sf->name);
	if(c == nil){
		fprint(2, "subfont %s not cached\n", sf->name);
		return;
	}
	if(c->ref > 0)
		c->ref--;
	/* if ref is zero, we leave it around for later harvesting by freeallsubfonts */
}

void
freeallsubfonts(Display *d)
{
	int i;
	Cache *c, *prev, *o;
	Subfont *sf;
	int locked;
	if(cacheqlock == nil)	/* may not have allocated anything yet */
		return;
	libqlock(cacheqlock);
	for(i=0; i<BIHASH; i++){
		c = sfcache[i];
		prev = 0;
		while(c != nil){
			if(c->ref==0 && (d==nil || c->display==d)){
				if(prev == 0)
					sfcache[i] = c->next;
				else
					prev->next = c->next;
				free(c->name);
				sf = c->u.sf;
				if(--sf->ref==0){
					free(sf->info);
					locked = lockdisplay(c->display);
					freeimage(sf->bits);
					if(locked)
						unlockdisplay(c->display);
					free(sf);
				}
				o = c;
				c = c->next;
				free(o);
			}else{
				prev = c;
				c = c->next;
			}
		}
	}
	libqunlock(cacheqlock);
}

void
subfont_close(Subfont *sf)
{
	freecachedsubfont(sf);
}

void
freesubfont(Subfont *sf)
{
	freecachedsubfont(sf);
}

void
Font_open(void *fp)
{
	Font *font;
	Display *disp;
	DFont *df;
	F_Font_open *f;

	f = fp;

	destroy(*f->ret);
	*f->ret = H;
	disp = checkdisplay(f->d);

	df = newdfont();
	*f->ret = &df->drawfont;
	font = font_open(disp, string2c(f->name));
	if(font == 0){
		*f->ret = H;
		destroy(&df->drawfont);
		return;
	}
	filldfont(df, font, f->name, f->d, disp);
}

void
Font_width(void *fp)
{
	F_Font_width *f;
	Font *font;
	char *s;
	int locked;

	f = fp;
	s = string2c(f->str);
	if(f->f == H || s[0]=='\0')
		*f->ret = 0;
	else{
		font = checkfont(f->f);
		locked = lockdisplay(font->display);
		*f->ret = stringwidth(font, s);
		if(locked)
			unlockdisplay(font->display);
	}
}

void
Font_bbox(void *fp)
{
	F_Font_bbox *f;
	Draw_Rect *ret;

	/* place holder for the real thing */
	f = fp;
	ret = f->ret;
	ret->min.x = ret->min.y = 0;
	ret->max.x = ret->max.y = 0;
}

/*
 * BUG: would be nice if this cached the whole font.
 * Instead only the subfonts are cached and the fonts are
 * freed when released.
 */
void
freedrawfont(Heap*h, int swept)
{
	Draw_Font *d;
	Font *f;
	d = H2D(Draw_Font*, h);
	f = lookupfont(d);
	if(!swept) {
		destroy(d->name);
		destroy(d->display);
	}
	if(f == nil)	/* a cell no font was put in */
		return;
	font_close(f);
	display_dec(((DFont*)d)->dref);
}

void
Chans_text(void *fp)
{
	F_Chans_text *f;
	char buf[16];

	f = fp;
	destroy(*f->ret);
	*f->ret = H;
	if(chantostr(buf, f->c.desc) != nil)
		retstr(buf, f->ret);
}

void
Chans_depth(void *fp)
{
	F_Chans_depth *f;

	f = fp;
	*f->ret = chantodepth(f->c.desc);
}

void
Chans_eq(void *fp)
{
	F_Chans_eq *f;

	f = fp;
	*f->ret = f->c.desc == f->d.desc;
}

void
Chans_mk(void *fp)
{
	F_Chans_mk *f;

	f = fp;
	f->ret->desc = strtochan(string2c(f->s));
}

void
Display_rgb(void *fp)
{
	ulong c;
	F_Display_rgb *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	checkdisplay(f->d);

	c = ((f->r&255)<<24)|((f->g&255)<<16)|((f->b&255)<<8)|0xFF;

	color(f->ret, (DDisplay*)f->d, c);
}

void
Display_rgb2cmap(void *fp)
{
	F_Display_rgb2cmap *f;

	f = fp;
	/* f->display is unused, but someday may have color map */
	*f->ret = rgb2cmap(f->r, f->g, f->b);
}

void
Display_cmap2rgb(void *fp)
{
	F_Display_cmap2rgb *f;
	ulong c;

	f = fp;
	/* f->display is unused, but someday may have color map */
	c = cmap2rgb(f->c);
	f->ret->t0 = (c>>16)&0xFF;
	f->ret->t1 = (c>>8)&0xFF;
	f->ret->t2 = (c>>0)&0xFF;
}

void
Display_cmap2rgba(void *fp)
{
	F_Display_cmap2rgba *f;

	f = fp;
	/* f->display is unused, but someday may have color map */
	*f->ret = cmap2rgba(f->c);
}

void
Draw_setalpha(void *fp)
{
	F_Draw_setalpha *f;

	f = fp;
	*f->ret = setalpha(f->c, f->a);
}

void
Draw_icossin(void *fp)
{
	F_Draw_icossin *f;
	int s, c;

	f = fp;
	icossin(f->deg, &s, &c);
	f->ret->t0 = s;
	f->ret->t1 = c;
}

void
Draw_icossin2(void *fp)
{
	F_Draw_icossin2 *f;
	int s, c;

	f = fp;
	icossin2(f->p.x, f->p.y, &s, &c);
	f->ret->t0 = s;
	f->ret->t1 = c;
}

void
Draw_bytesperline(void *fp)
{
	F_Draw_bytesperline *f;

	f = fp;
	/* libdraw aborts on a depth no image has, and emu went with it */
	if(f->d <= 0 || f->d > 32)
		error(exInval);
	*f->ret = bytesperline(IRECT(f->r), f->d);
}

static void
color(Draw_Image **ret, DDisplay *dd, ulong color)
{
	int c;
	Draw_Rect r;

	r.min.x = 0;
	r.min.y = 0;
	r.max.x = 1;
	r.max.y = 1;
	c = (color&0xff) == 0xff ? RGB24: RGBA32;
	allocdrawimage(ret, dd, r, c, 1, color);
}

/*
 * A Draw->Image is made in two steps: its cell, then the image to put
 * in it.  heap() raises when the heap is full, and it was called once
 * the image had been made, often with the display locked: the image
 * was lost, and on a remote display the lock was held for good, so
 * every other user of the display waited for ever.  The cell comes
 * first, and its maker puts it in its result, where the collector can
 * see it, before the display is asked for anything (which lets other
 * Progs run); if the display refuses, the result is nil again and the
 * cell, with no image in it, frees as nothing.
 */
static DImage*
newdimage(void)
{
	return H2D(DImage*, heap(TImage));
}

static Draw_Image*
filldimage(DImage *di, Image *i, Draw_Screen *screen, Draw_Display *display, void *ref)
{
	di->image = i;
	di->drawimage.screen = screen;
	if(screen != H)
		D2H(screen)->ref++;
	di->drawimage.display = display;
	if(display != H)
		D2H(display)->ref++;
	di->refreshptr = ref;

	R2R(di->drawimage.r, i->r);
	R2R(di->drawimage.clipr, i->clipr);
	di->drawimage.chans.desc = i->chan;
	di->drawimage.depth = i->depth;
	di->drawimage.repl = i->repl;
	di->flush = 1;
	di->dref = i->display->limbo;
	di->dref->ref++;
	return &di->drawimage;
}

Draw_Image*
mkdrawimage(Image *i, Draw_Screen *screen, Draw_Display *display, void *ref)
{
	/*
	 * No image, no Draw->Image. Every allocation below can fail once
	 * the display has gone -- a remote /dev/draw whose connection hung
	 * up (cpu(1) from a desktop, then the desktop closes) fails every
	 * request -- and a caller that forgets to check hands nil in here.
	 * On the bare-metal kernel page zero is mapped, so i->r would not
	 * fault: it read kernel text as a pointer and the dereference of
	 * that took the machine down (Display_colormix, 2026-09-29).
	 */
	if(i == nil)
		return H;

	return filldimage(newdimage(), i, screen, display, ref);
}

void
Screen_newwindow(void *fp)
{
	F_Screen_newwindow *f;
	Image *i;
	DImage *di;
	Screen *s;
	Rectangle r;
	int locked;
	void *v;

	f = fp;
	s = checkscreen(f->screen);
	R2R(r, f->r);

	if(f->backing != Refnone && f->backing != Refbackup)
		f->backing = Refbackup;

	v = *f->ret;
	*f->ret = H;
	destroy(v);

	di = newdimage();	/* before the window, which would be lost if this raised */
	*f->ret = &di->drawimage;
	locked = lockdisplay(s->display);
	i = allocwindow(s, r, f->backing, f->color);
	if(locked)
		unlockdisplay(s->display);
	if(i == nil){
		*f->ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, i, f->screen, f->screen->display, 0);
}

static
void
screentopbot(Draw_Screen *screen, Array *array, void (*topbot)(Image **, int))
{
	Screen *s;
	Draw_Image **di;
	Image **ip;
	int i, n, locked;

	s = checkscreen(screen);
	if(array == H)
		error(exNilref);
	di = (Draw_Image**)array->data;
	ip = malloc(array->len * sizeof(Image*));
	if(ip == nil)
		return;
	n = 0;
	for(i=0; i<array->len; i++)
		if(di[i] != H){
			ip[n] = lookupimage(di[i]);
			if(ip[n]==nil || ip[n]->screen != s){
				free(ip);
				return;
			}
			n++;
		}
	if(n == 0){
		free(ip);
		return;
	}
	locked = lockdisplay(s->display);
	(*topbot)(ip, n);
	free(ip);
	flushimage(s->display, 1);
	if(locked)
		unlockdisplay(s->display);
}

void
Screen_top(void *fp)
{
	F_Screen_top *f;
	f = fp;
	screentopbot(f->screen, f->wins, topnwindows);
}

void
Screen_bottom(void *fp)
{
	F_Screen_top *f;
	f = fp;
	screentopbot(f->screen, f->wins, bottomnwindows);
}

void
freedrawimage(Heap *h, int swept)
{
	Image *i;
	int locked;
	Display *disp;
	Draw_Image *d;

	d = H2D(Draw_Image*, h);
	i = lookupimage(d);
	if(i == nil) {
		if(!swept)
			freeptrs(d, TImage);
		return;
	}
	disp = i->display;
	locked = lockdisplay(disp);
	freeimage(i);
	if(locked)
		unlockdisplay(disp);
	display_dec(((DImage*)d)->dref);
	/* image/layer header will be freed by caller */
}

void
Image_top(void *fp)
{
	F_Image_top *f;
	Image *i;
	int locked;

	f = fp;
	i = checkimage(f->win);
	locked = lockdisplay(i->display);
	topwindow(i);
	flushimage(i->display, 1);
	if(locked)
		unlockdisplay(i->display);
}

void
Image_origin(void *fp)
{
	F_Image_origin *f;
	Image *i;
	int locked;

	f = fp;
	i = checkimage(f->win);
	locked = lockdisplay(i->display);
	if(originwindow(i, IPOINT(f->log), IPOINT(f->scr)) < 0)
		*f->ret = -1;
	else{
		f->win->r = DRECT(i->r);
		f->win->clipr = DRECT(i->clipr);
		*f->ret = 1;
	}
	if(locked)
		unlockdisplay(i->display);
}

void
Image_bottom(void *fp)
{
	F_Image_top *f;
	Image *i;
	int locked;

	f = fp;
	i = checkimage(f->win);
	locked = lockdisplay(i->display);
	bottomwindow(i);
	flushimage(i->display, 1);
	if(locked)
		unlockdisplay(i->display);
}

/*
 * A new image on the display, in *ret (the caller's result, so the
 * collector sees the cell while the display is asked); H if the
 * display refuses it.  It takes the display's lock itself: its
 * callers held it across the call, heap() and all.
 */
static void
allocdrawimage(Draw_Image **ret, DDisplay *ddisplay, Draw_Rect r, ulong chan, int repl, int color)
{
	DImage *di;
	Rectangle rr;
	Image *image;
	Display *d;
	int locked;

	di = newdimage();
	*ret = &di->drawimage;
	d = ddisplay->display;
	R2R(rr, r);
	locked = lockdisplay(d);
	image = allocimage(d, rr, chan, repl, color);
	if(locked)
		unlockdisplay(d);
	if(image == nil){
		*ret = H;
		destroy(&di->drawimage);
		return;
	}
	filldimage(di, image, H, (Draw_Display*)ddisplay, nil);
}

/*
 * Entry points called from the draw library
 */
Subfont*
lookupsubfont(Display *d, char *name)
{
	Cache *c;

	/*
	 * The built-in font is not in the cache and never will be: it is
	 * built by getdefont() when the Display is allocated and kept on
	 * the Display itself, not installed through installsubfont.
	 *
	 * libdraw's own lookupsubfont -- the one this replaces, in
	 * libdraw/subfontcache.c -- answers this name from
	 * d->defaultsubfont, and dropping that case is why "*default*"
	 * could be opened and MEASURED but never drawn. The metrics live
	 * in the Font, which buildfont fills in from the same byte array,
	 * so a program asking for the width of a string got a sensible
	 * number; the glyphs live in the subfont, which loadchar could
	 * not find, so nothing appeared. A label that lays out at the
	 * right size and draws nothing.
	 *
	 * It goes unnoticed on any machine with /fonts, because then
	 * "*default*" is never asked for. This kernel has no font files
	 * at all, which is how it turned up.
	 */
	if(strcmp(name, deffontname) == 0)
		return d->defaultsubfont;

	c = cachelookup(sfcache, d, name);
	if(c == nil)
		return nil;
	/*c->u.sf->ref++;*/	/* TO DO: need to revisit the reference counting */
	return c->u.sf;
}

void
installsubfont(char *name, Subfont *subfont)
{
	Cache *c;

	c = cacheinstall(sfcache, subfont->bits->display, name, subfont, "subfont");
	if(c)
		c->ref++;
}

/*
 * BUG version
 */
char*
subfontname(char *cfname, char *fname, int maxdepth)
{
	char *t, *u, tmp1[256], tmp2[256];
	int i, fd;

	if(strcmp(cfname, deffontname) == 0)
		return strdup(cfname);
	t = cfname;
	if(t[0] != '/'){
		if(strlen(fname) >= sizeof(tmp2))
			return nil;
		strncpy(tmp2, fname, sizeof(tmp2)-1);
		tmp2[sizeof(tmp2)-1] = 0;
		u = utfrrune(tmp2, '/');
		if(u)
			u[0] = 0;
		else
			strcpy(tmp2, ".");
		snprint(tmp1, sizeof tmp1, "%s/%s", tmp2, t);
		t = tmp1;
	}

	if(maxdepth > 8)
		maxdepth = 8;

	for(i=3; i>=0; i--){
		if((1<<i) > maxdepth)
			continue;
		/* try i-bit grey */
		snprint(tmp2, sizeof tmp2, "%s.%d", t, i);
		fd = libopen(tmp2, OREAD);
		if(fd >= 0){
			libclose(fd);
			return strdup(tmp2);
		}
	}

	return strdup(t);
}

void
refreshslave(Display *d)
{
	int i, n, id;
	uchar buf[5*(5*4)], *p;
	Rectangle r;
	Image *im;
	int locked;

	for(;;){
		release();
		n = kchanio(d->refchan, buf, sizeof buf, OREAD);
		acquire();
		if(n < 0)	/* probably caused by closedisplay() closing refchan */
			return;	/* will fall off end of thread and close down */
		locked = lockdisplay(d);
		p = buf;
		for(i=0; i<n; i+=5*4,p+=5*4){
			id = BGLONG(p+0*4);
			r.min.x = BGLONG(p+1*4);
			r.min.y = BGLONG(p+2*4);
			r.max.x = BGLONG(p+3*4);
			r.max.y = BGLONG(p+4*4);
			for(im=d->windows; im; im=im->next)
				if(im->id == id)
					break;
			if(im && im->screen && im->reffn)
				(*im->reffn)(im, r, im->refptr);
		}
		flushimage(d, 1);
		if(locked)
			unlockdisplay(d);
	}
}

void
startrefresh(Display *disp)
{
	USED(disp);
}

static
int
doflush(Display *d)
{
	int m, n;
	char err[ERRMAX];
	uchar *tp;

	n = d->bufp-d->buf;
	if(n <= 0)
		return 1;

	/* the display's lock, not the VM, keeps the buffer (lockdisplay) */
	release();
	if((m = kchanio(d->datachan, d->buf, n, OWRITE)) != n){
		acquire();
		kgerrstr(err, sizeof err);
		if(_drawdebug || strcmp(err, "screen id in use") != 0 && strcmp(err, exImage) != 0){
			print("flushimage fail: (%d not %d) d=%lux: %s\n", m, n, (ulong)d, err);
			/* the message itself, up to 8000 bytes of it as hex, only when asked */
			if(_drawdebug){
				print("buffer: ");
				for(tp = d->buf; tp < d->bufp; tp++)
					print("%.2x ", (int)*tp);
				print("\n");
			}
		}
		d->bufp = d->buf;	/* might as well; chance of continuing */
		return -1;
	}
	d->bufp = d->buf;
	acquire();
	return 1;
}

int
flushimage(Display *d, int visible)
{
	int ret;
	Refreshq *r;

	for(;;){
		if(visible)
			*d->bufp++ = 'v';	/* one byte always reserved for this */
		ret = doflush(d);
		if(d->refhead == nil)
			break;
		while(r = d->refhead){	/* assign = */
			d->refhead = r->next;
			if(d->refhead == nil)
				d->reftail = nil;
			r->reffn(nil, r->r, r->refptr);
			free(r);
		}
	}
	return ret;
}

/*
 * Turn off refresh for this window and remove any pending refresh events for it.
 */
void
delrefresh(Image *i)
{
	Refreshq *r, *prev, *next;
	int locked;
	Display *d;
	void *refptr;

	d = i->display;
	/*
	 * Any refresh function will do, because the data pointer is nil.
	 * Can't use nil, though, because that turns backing store back on.
	 */
	if(d->local)
		drawlsetrefresh(d->dataqid, i->id, memlnorefresh, nil);
	refptr = i->refptr;
	i->refptr = nil;
	if(d->refhead==nil || refptr==nil)
		return;
	locked = lockdisplay(d);
	prev = nil;
	for(r=d->refhead; r; r=next){
		next = r->next;
		if(r->refptr == refptr){
			if(prev)
				prev->next = next;
			else
				d->refhead = next;
			if(d->reftail == r)
				d->reftail = prev;
			free(r);
		}else
			prev = r;
	}
	if(locked)
		unlockdisplay(d);
}

void
queuerefresh(Image *i, Rectangle r, Reffn reffn, void *refptr)
{
	Display *d;
	Refreshq *rq;

	d = i->display;
	rq = malloc(sizeof(Refreshq));
	if(rq == nil)
		return;
	if(d->reftail)
		d->reftail->next = rq;
	else
		d->refhead = rq;
	d->reftail = rq;
	rq->reffn = reffn;
	rq->refptr = refptr;
	rq->r = r;
}

uchar*
bufimage(Display *d, int n)
{
	uchar *p;

	if(n<0 || n>Displaybufsize){
		kwerrstr("bad count in bufimage");
		return 0;
	}
	if(d->bufp+n > d->buf+Displaybufsize){
		if(currun()!=libqlowner(d->qlock)) {
			print("bufimage: %lux %lux\n", (ulong)libqlowner(d->qlock), (ulong)currun());
			abort();
		}
		if(doflush(d) < 0)
			return 0;
	}
	p = d->bufp;
	d->bufp += n;
	/* return with buffer locked */
	return p;
}

uchar*
_bufimageop(Display *d, int n, Drawop op)
{
	uchar *a;

	if(op != SoverD){
		a = bufimage(d, 2+n);
		if(a == nil)
			return nil;
		a[0] = 'O';
		a[1] = op;
		return a+2;
	}
	return bufimage(d, n);
}

void
drawerror(Display *d, char *s)
{
	USED(d);
	fprint(2, "draw: %s: %r\n", s);
}
