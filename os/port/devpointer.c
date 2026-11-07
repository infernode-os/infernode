/*
 * #m -- the pointer, as a file.
 *
 * A mouse is not a driver interface here, it is a FILE. Anything that
 * can write "m x y b" to /dev/pointer is a pointing device: the USB
 * mouse driver is a Limbo program that does exactly that, and so is a
 * test injecting a click over 9P, and neither is privileged over the
 * other. Reading the file gives the current position and buttons.
 *
 * Derived from emu/port/devpointer.c.
 *
 * /dev/cursor came back with the draw device, which is what it needs:
 * a write hands a shape to drawcursor(), and os/fb/screen.c paints
 * it in software because this SoC's scanout path has no hardware
 * cursor. Without it the pointer is invisible -- the mouse works
 * perfectly and there is simply nothing on the screen to show where it
 * is, which is not a difference a person can be expected to reason
 * about.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	<cursor.h>

static Drawcursor cur;

/*
 * Little-endian 32-bit, as the cursor message carries them.
 *
 * include/draw.h has BGLONG for this, but cursor.h is a separate file
 * precisely so that a driver need not include draw.h -- the comment at
 * the top of it says so -- and four lines here is cheaper than the name
 * conflicts that would come with it.
 */
static int
getl(uchar *p)
{
	return p[0] | (p[1]<<8) | (p[2]<<16) | (p[3]<<24);
}

enum{
	Qdir,
	Qpointer,
	Qcursor,
	Qfingers,
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
	"cursor",	{Qcursor},		0,	0222,
	"fingers",	{Qfingers},		0,	0666,
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
	/*
	 * Follow the pointer with the software cursor. Done here rather
	 * than in the queueing below because MOVEMENT is what the cursor
	 * tracks, and movement is deliberately not queued.
	 */
	swcursorat(x, y);
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

/*
 * /dev/fingers: every finger on a touch screen, each a pointer of its
 * own, as emu's (emu/port/devpointer.c, whose comment says why).  Here
 * the only source is a write: the touch panel's driver is a program
 * (os/init/touch.b), which writes "f<id> <x> <y> <on>" for each finger
 * it reads, as it writes the first one to /dev/pointer.  Each read is
 * one event, "f<id> <x> <y> <on> <msec>"; one reader at a time; with
 * none, events are dropped.
 */
typedef struct Finger Finger;
struct Finger
{
	int	id;
	int	x;
	int	y;
	int	on;
	ulong	msec;
};

enum
{
	Nfinger	= 128,
	Nfingerlift = 16,	/* of those, kept for lifts */
};

static struct
{
	Lock	l;
	QLock	rq;		/* procs sharing the reader's fd read one at a time */
	QLock	wq;		/* writers wait for room one at a time */
	Rendez	r;		/* the reader waits for an event */
	Rendez	w;		/* a writer waits for room */
	int	reading;	/* a reader has it open */
	Finger	e[Nfinger];
	int	rd;
	int	n;
} fq;

/* 1 if queued or dropped for want of a reader, 0 if there is no room */
static int
fingerput(int id, int x, int y, int on)
{
	Finger *f;

	ilock(&fq.l);
	if(!fq.reading){
		iunlock(&fq.l);
		return 1;
	}
	if(fq.n >= (on ? Nfinger-Nfingerlift : Nfinger)){
		iunlock(&fq.l);
		return 0;
	}
	f = &fq.e[(fq.rd+fq.n) % Nfinger];
	f->id = id;
	f->x = x;
	f->y = y;
	f->on = on != 0;
	f->msec = TK2MS(MACHP(0)->ticks);
	fq.n++;
	iunlock(&fq.l);
	wakeup(&fq.r);
	return 1;
}

static int
fingerready(void *a)
{
	USED(a);
	return fq.n > 0;
}

static int
fingerroom(void *a)
{
	USED(a);
	return !fq.reading || fq.n < Nfinger-Nfingerlift;
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
	if((ulong)c->qid.path == Qcursor && (omode & 3) == OREAD)
		error(Eperm);
	if((ulong)c->qid.path == Qpointer && (omode & 3) != OWRITE)
		incref(&mouse.ref);
	if((ulong)c->qid.path == Qfingers && (omode & 3) != OWRITE){
		ilock(&fq.l);
		if(fq.reading){
			iunlock(&fq.l);
			c->flag &= ~COPEN;
			error(Einuse);
		}
		fq.reading = 1;
		fq.n = 0;
		iunlock(&fq.l);
	}
	return c;
}

static void
pointerclose(Chan* c)
{
	if((c->flag & COPEN) == 0)
		return;
	if((ulong)c->qid.path == Qfingers){
		if((c->mode & 3) == OWRITE)
			return;
		ilock(&fq.l);
		fq.reading = 0;
		fq.n = 0;
		iunlock(&fq.l);
		wakeup(&fq.w);
		return;
	}
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
	Finger f;
	char buf[1+5*12+1];
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
	case Qfingers:
		qlock(&fq.rq);
		if(waserror()){
			qunlock(&fq.rq);
			nexterror();
		}
		sleep(&fq.r, fingerready, nil);
		poperror();
		qunlock(&fq.rq);
		ilock(&fq.l);
		if(fq.n == 0){
			iunlock(&fq.l);
			return 0;
		}
		f = fq.e[fq.rd];
		fq.rd = (fq.rd+1) % Nfinger;
		fq.n--;
		iunlock(&fq.l);
		wakeup(&fq.w);
		l = snprint(buf, sizeof(buf), "f%11d %11d %11d %11d %11lud ",
			f.id, f.x, f.y, f.on, f.msec);
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
		 * "m x y b" is a position; "d dx dy b" is movement; "a x y b"
		 * is a position as a fraction of the screen (below).
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
		/*
		 * "a x y b": a position as a fraction of the screen, x and y
		 * in 0..65535. A touchscreen or a tablet knows where on its
		 * surface it is touched but not how big the screen is; only
		 * this device has the bounds (pointerbounds), so the scaling
		 * is done once, here, for every absolute source. Before the
		 * console has said how big the screen is there is nothing to
		 * scale to, and the report is dropped rather than guessed at.
		 */
		if(buf[0] == 'a'){
			if(mouse.maxx <= 0 || mouse.maxy <= 0)
				break;
			if(x > 65535)
				x = 65535;
			if(y > 65535)
				y = 65535;
			x = (int)(((vlong)x * mouse.maxx) / 65536);
			y = (int)(((vlong)y * mouse.maxy) / 65536);
		}
		mousetrack(b, x, y, isdelta);
		break;

	case Qfingers:
		if(n > sizeof buf-1)
			n = sizeof buf -1;
		memmove(buf, va, n);
		buf[n] = 0;
		/*
		 * "f<id> x y on" in the screen's pixels, the touch panel's;
		 * "a<id> x y on" in fractions of it, 0..65535, a USB
		 * touchscreen's (os/init/mouseusb.b), scaled as /dev/pointer's
		 * "a x y b" is, and dropped as it is before the console has
		 * said how big the screen is.
		 */
		if(buf[0] != 'f' && buf[0] != 'a')
			error(Ebadarg);
		a = buf + 1;
		b = strtoul(a, &a, 0);		/* the finger's id */
		x = strtoul(a, &a, 0);
		y = strtoul(a, &a, 0);
		if(*a == 0)
			error(Eshort);
		isdelta = strtoul(a, 0, 0);	/* on the screen */
		if(buf[0] == 'a'){
			if(mouse.maxx <= 0 || mouse.maxy <= 0)
				break;
			if(x > 65535)
				x = 65535;
			if(y > 65535)
				y = 65535;
			x = (int)(((vlong)x * mouse.maxx) / 65536);
			y = (int)(((vlong)y * mouse.maxy) / 65536);
		}
		qlock(&fq.wq);
		if(waserror()){
			qunlock(&fq.wq);
			nexterror();
		}
		while(!fingerput(b, x, y, isdelta))
			sleep(&fq.w, fingerroom, nil);
		poperror();
		qunlock(&fq.wq);
		break;

	case Qcursor:
		/*
		 *  hotx[4] hoty[4] dx[4] dy[4] clr[dx/8 * dy/2] set[dx/8 * dy/2]
		 *  dx must be a multiple of 8; dy must be a multiple of 2.
		 *
		 * Byte for byte what emu/port/devpointer.c accepts, so a
		 * program that sets a cursor does not have to know which
		 * kernel it is talking to. An empty write clears it.
		 */
		if(n == 0){
			cur.data = nil;
			drawcursor(&cur);
			break;
		}
		if(n < 4*4)
			error(Eshort);
		cur.hotx = getl((uchar*)va+0*4);
		cur.hoty = getl((uchar*)va+1*4);
		cur.minx = 0;
		cur.miny = 0;
		cur.maxx = getl((uchar*)va+2*4);
		cur.maxy = getl((uchar*)va+3*4);
		if(cur.maxx%8 != 0 || cur.maxy%2 != 0
		|| n-4*4 != (cur.maxx/8 * cur.maxy))
			error(Ebadarg);
		cur.data = (uchar*)va + 4*4;
		drawcursor(&cur);
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
