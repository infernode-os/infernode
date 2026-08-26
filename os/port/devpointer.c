/*
 * #m -- the pointer, as a file.
 *
 * A mouse is not a driver interface here, it is a FILE. Anything that
 * can write "m x y b" to /dev/pointer is a pointing device: the USB
 * mouse driver is a Limbo program that does exactly that, and so is a
 * test injecting a click over 9P, and neither is privileged over the
 * other. Reading the file gives the current position and buttons.
 *
 * Derived from emu/port/devpointer.c and deliberately SMALLER than it.
 * The emu version also serves /dev/cursor, which takes an image and
 * hands it to drawcursor(); this kernel has no draw device yet, so that
 * file would be an entry point to code that does not exist. It can come
 * back with devdraw.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

enum{
	Qdir,
	Qpointer,
};

typedef struct Pointer Pointer;

struct Pointer {
	int	x;
	int	y;
	int	b;
	ulong	msec;
};

static struct
{
	Pointer	v;
	int	lastb;
	Ref	ref;
	QLock	q;
	int	maxx;		/* 0 until someone says how big the screen is */
	int	maxy;
} mouse;

static
Dirtab pointertab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"pointer",	{Qpointer},		0,	0666,
};

enum {
	Nevent = 16	/* enough for some */
};

static struct {
	int	rd;
	int	wr;
	Pointer	clicks[Nevent];
	Rendez	r;
	int	full;
	int	put;
	int	get;
} ptrq;

/*
 * Where the pointer is allowed to be.
 *
 * A mouse reports MOVEMENT, not position, so something has to decide
 * what it has moved within or the accumulated position wanders off the
 * screen and never comes back. The console knows how big the screen is;
 * nothing else here does, so it says.
 *
 * Until it does, the position is left unclamped rather than clamped to
 * a guess: a wrong bound is worse than none, because it silently pins
 * the pointer to an edge that is not there.
 */
void
pointerbounds(int w, int h)
{
	mouse.maxx = w;
	mouse.maxy = h;
}

/*
 * Called by any source of pointer data.
 *
 * isdelta is what a mouse uses: it reports how far it moved, and the
 * accumulated position lives here rather than in every driver that
 * might report one.
 */
void
mousetrack(int b, int x, int y, int isdelta)
{
	int lastb;
	ulong msec;

	if(isdelta){
		x += mouse.v.x;
		y += mouse.v.y;
	}
	if(mouse.maxx > 0){
		if(x < 0)
			x = 0;
		if(y < 0)
			y = 0;
		if(x >= mouse.maxx)
			x = mouse.maxx - 1;
		if(y >= mouse.maxy)
			y = mouse.maxy - 1;
	}

	msec = TK2MS(MACHP(0)->ticks);

	if(x == mouse.v.x && y == mouse.v.y && mouse.v.b == b)
		return;

	lastb = mouse.v.b;
	mouse.v.x = x;
	mouse.v.y = y;
	mouse.v.b = b;
	mouse.v.msec = msec;

	/*
	 * Queue only BUTTON changes.
	 *
	 * Movement is state: a reader wants where the pointer is now, not
	 * every place it has been, and queueing each motion report would
	 * fill sixteen slots during one flick of the wrist and then drop
	 * the click that followed. A press or release is an event and
	 * cannot be recovered by looking at the current position later.
	 */
	if(!ptrq.full && lastb != b){
		ptrq.clicks[ptrq.wr] = mouse.v;
		if(++ptrq.wr >= Nevent)
			ptrq.wr = 0;
		if(ptrq.wr == ptrq.rd)
			ptrq.full = 1;
	}
	ptrq.put++;
	wakeup(&ptrq.r);
}

static int
ptrqnotempty(void *x)
{
	USED(x);
	return ptrq.full || ptrq.put != ptrq.get || ptrq.wr != ptrq.rd;
}

static Pointer
mouseconsume(void)
{
	Pointer e;

	sleep(&ptrq.r, ptrqnotempty, 0);
	ptrq.full = 0;
	ptrq.get = ptrq.put;
	if(ptrq.rd != ptrq.wr){
		e = ptrq.clicks[ptrq.rd];
		if(++ptrq.rd >= Nevent)
			ptrq.rd = 0;
	}else
		e = mouse.v;
	return e;
}

static Chan*
pointerattach(char* spec)
{
	return devattach('m', spec);
}

static Walkqid*
pointerwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, pointertab, nelem(pointertab), devgen);
}

static int
pointerstat(Chan* c, uchar *db, int n)
{
	return devstat(c, db, n, pointertab, nelem(pointertab), devgen);
}

static Chan*
pointeropen(Chan* c, int omode)
{
	c = devopen(c, omode, pointertab, nelem(pointertab), devgen);
	if((ulong)c->qid.path == Qpointer && (omode & 3) != OWRITE)
		incref(&mouse.ref);
	return c;
}

static void
pointerclose(Chan* c)
{
	if((c->flag & COPEN) == 0)
		return;
	if((ulong)c->qid.path != Qpointer)
		return;
	/*
	 * A write-only injector -- the mouse driver itself -- never took
	 * the reader's reference in pointeropen, so it must not drop one
	 * here.
	 */
	if((c->mode & 3) == OWRITE)
		return;
	qlock(&mouse.q);
	decref(&mouse.ref);
	qunlock(&mouse.q);
}

static long
pointerread(Chan* c, void* a, long n, vlong off)
{
	Pointer mt;
	char buf[1+4*12+1];
	int l;

	USED(off);
	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, pointertab, nelem(pointertab), devgen);
	case Qpointer:
		qlock(&mouse.q);
		if(waserror()) {
			qunlock(&mouse.q);
			nexterror();
		}
		mt = mouseconsume();
		poperror();
		qunlock(&mouse.q);
		l = snprint(buf, sizeof(buf), "m%11d %11d %11d %11lud ",
			mt.x, mt.y, mt.b, mt.msec);
		if(l < n)
			n = l;
		memmove(a, buf, n);
		break;
	default:
		n = 0;
		break;
	}
	return n;
}

static long
pointerwrite(Chan* c, void* va, long n, vlong off)
{
	char *a;
	char buf[128];
	int b, x, y, isdelta;

	USED(off);
	switch((ulong)c->qid.path){
	case Qpointer:
		if(n > sizeof buf-1)
			n = sizeof buf -1;
		memmove(buf, va, n);
		buf[n] = 0;

		/*
		 * "m x y b" is a position; "d dx dy b" is movement.
		 *
		 * Both exist because the two callers genuinely differ. A
		 * mouse reports movement and nothing else -- a HID report
		 * carries dx and dy, never a position -- so a driver that
		 * had to send absolute coordinates would have to keep the
		 * accumulated position itself, and every such driver would
		 * keep its own. Anything that already knows where it wants
		 * the pointer, a test or a window system, says so directly.
		 */
		isdelta = buf[0] == 'd';
		a = buf + 1;
		x = strtoul(a, &a, 0);
		if(*a == 0)
			error(Eshort);
		y = strtoul(a, &a, 0);
		if(*a != 0)
			b = strtoul(a, 0, 0);
		else
			b = mouse.v.b;
		mousetrack(b, x, y, isdelta);
		break;
	default:
		error(Ebadusefd);
	}
	return n;
}

Dev pointerdevtab = {
	'm',
	"pointer",

	devreset,
	devinit,
	devshutdown,
	pointerattach,
	pointerwalk,
	pointerstat,
	pointeropen,
	devcreate,
	pointerclose,
	pointerread,
	devbread,
	pointerwrite,
	devbwrite,
	devremove,
	devwstat,
};
