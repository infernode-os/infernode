/*
 * mouse or stylus
 */

#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>

#define	cursorenable()
#define	cursordisable()

enum{
	Qdir,
	Qpointer,
	Qcursor,
	Qfingers
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
	int	modify;
	int	lastb;
	Rendez	r;
	Ref	ref;
	QLock	q;
} mouse;

static
Dirtab pointertab[]={
	".",			{Qdir, 0, QTDIR},	0,	0555,
	"pointer",		{Qpointer},	0,	0666,
	"cursor",		{Qcursor},		0,	0222,
	"fingers",		{Qfingers},	0,	0666,
};

enum {
	Nevent = 16	/* enough for some */
};

static struct {
	int	rd;
	int	wr;
	Pointer	clicks[Nevent];
	Rendez r;
	Rendez w;	/* an injected event waits here for room */
	int	full;
	int	put;
	int	get;
} ptrq;

/*
 * called by any source of pointer data
 */
void
mousetrack(int b, int x, int y, int isdelta)
{
	int lastb;
	ulong msec;
	Pointer e;

	if(isdelta){
		x += mouse.v.x;
		y += mouse.v.y;
	}
	msec = osmillisec();
	if(0 && b && (mouse.v.b ^ b)&0x1f){
		if(msec - mouse.v.msec < 300 && mouse.lastb == b
		   && abs(mouse.v.x - x) < 12 && abs(mouse.v.y - y) < 12)
			b |= 1<<8;
		mouse.lastb = b & 0x1f;
		mouse.v.msec = msec;
	}
	if((b&(1<<8))==0 && x == mouse.v.x && y == mouse.v.y && mouse.v.b == b && !(b&(8|16)))
		return;
	lastb = mouse.v.b;
	mouse.v.x = x;
	mouse.v.y = y;
	mouse.v.b = b;
	mouse.v.msec = msec;
	if(!ptrq.full && (lastb != b || (b&(8|16)))){
		e = mouse.v;
		ptrq.clicks[ptrq.wr] = e;
		if(++ptrq.wr >= Nevent)
			ptrq.wr = 0;
		if(ptrq.wr == ptrq.rd)
			ptrq.full = 1;
	}
	mouse.modify = 1;
	ptrq.put++;
	Wakeup(&ptrq.r);
/*	drawactive(1);	*/
/*	setpointer(x, y); */
}

/*
 * /dev/fingers: the fingers on a touch screen, each a pointer of its
 * own.  /dev/pointer is one pointer -- the first finger, as a mouse --
 * and stays so for everything that reads it; a program that needs
 * every finger (a keyboard on the screen, typed with two thumbs whose
 * touches overlap) reads this as well.  Each read is one event,
 *
 *	f<id> <x> <y> <on> <msec>
 *
 * in the fixed-width fields /dev/pointer uses: on is 1 while the
 * finger is on the screen and 0 when it lifts, and an id is a finger's
 * from the event it lands until the one it lifts, then free again.  A
 * write of "f<id> <x> <y> <on>" is such an event, from a driver that
 * is a program (the native kernel's touch) or a test.
 *
 * One reader at a time.  With none, events are dropped rather than
 * kept for a reader who comes later and would see touches long gone.
 * From the GUI backend an event is dropped if the queue is full, as it
 * may not wait; room is kept for the lifts, so a finger is not left on
 * the screen by an event lost.  A write waits for room.
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

	lock(&fq.l);
	if(!fq.reading){
		unlock(&fq.l);
		return 1;
	}
	if(fq.n >= (on ? Nfinger-Nfingerlift : Nfinger)){
		unlock(&fq.l);
		return 0;
	}
	f = &fq.e[(fq.rd+fq.n) % Nfinger];
	f->id = id;
	f->x = x;
	f->y = y;
	f->on = on != 0;
	f->msec = osmillisec();
	fq.n++;
	unlock(&fq.l);
	Wakeup(&fq.r);
	return 1;
}

/*
 * called by any source of touches: finger id is at x, y (screen
 * pixels) and on the screen, or has lifted (on 0)
 */
void
fingertrack(int id, int x, int y, int on)
{
	fingerput(id, x, y, on);
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

static int
ptrqnotfull(void *x)
{
	USED(x);
	return !ptrq.full;
}

/*
 * An event written to /dev/pointer (a test, any headless driver):
 * queued as it is, motion included, where mousetrack keeps only the
 * latest position between button changes, as a mouse's motion is.  A
 * drag written as press, move, release would otherwise lose the move
 * when the reader fell behind, and wm/wm's sweep, which takes its
 * rectangle from the motion while the button is held, came out too
 * small.  It waits for room rather than being dropped.
 */
static void
mouseinject(int b, int x, int y)
{
	Sleep(&ptrq.w, ptrqnotfull, 0);
	mouse.v.x = x;
	mouse.v.y = y;
	mouse.v.b = b;
	mouse.v.msec = osmillisec();
	ptrq.clicks[ptrq.wr] = mouse.v;
	if(++ptrq.wr >= Nevent)
		ptrq.wr = 0;
	if(ptrq.wr == ptrq.rd)
		ptrq.full = 1;
	mouse.modify = 1;
	ptrq.put++;
	Wakeup(&ptrq.r);
}

static Pointer
mouseconsume(void)
{
	Pointer e;

	Sleep(&ptrq.r, ptrqnotempty, 0);
	ptrq.full = 0;
	Wakeup(&ptrq.w);
	ptrq.get = ptrq.put;
	if(ptrq.rd != ptrq.wr){
		e = ptrq.clicks[ptrq.rd];
		if(++ptrq.rd >= Nevent)
			ptrq.rd = 0;
	}else
		e = mouse.v;
	return e;
}

Point
mousexy(void)
{
	return Pt(mouse.v.x, mouse.v.y);
}


static Chan*
pointerattach(char* spec)
{
	return devattach('m', spec);
}

static Walkqid*
pointerwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;

	wq = devwalk(c, nc, name, nname, pointertab, nelem(pointertab), devgen);
	if(wq != nil && wq->clone != c && wq->clone != nil && (ulong)c->qid.path == Qpointer)
		incref(&mouse.ref);	/* can this happen? */
	return wq;
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
	/*
	 * The read side is single-owner: exactly one reader drains the mouse
	 * event queue (the window system).  A write-only open does not touch
	 * that queue's ownership — it only injects events via pointerwrite —
	 * so let OWRITE opens coexist with the reader.  This lets a headless
	 * driver synthesise clicks while the window system is running.
	 */
	if((ulong)c->qid.path == Qfingers && (omode & 3) != OWRITE){
		lock(&fq.l);
		if(fq.reading){
			unlock(&fq.l);
			c->flag &= ~COPEN;
			error(Einuse);
		}
		fq.reading = 1;
		fq.n = 0;
		unlock(&fq.l);
	}
	if((ulong)c->qid.path == Qpointer && (omode & 3) != OWRITE){
		if(waserror()){
			c->flag &= ~COPEN;
			nexterror();
		}
		if(!canqlock(&mouse.q))
			error(Einuse);
		if(incref(&mouse.ref) != 1){
			qunlock(&mouse.q);
			error(Einuse);
		}
		cursorenable();
		qunlock(&mouse.q);
		poperror();
	}
	return c;
}

static void
pointerclose(Chan* c)
{
	if((c->flag & COPEN) == 0)
		return;
	switch((ulong)c->qid.path){
	case Qfingers:
		if((c->mode & 3) == OWRITE)
			break;
		lock(&fq.l);
		fq.reading = 0;
		fq.n = 0;
		unlock(&fq.l);
		Wakeup(&fq.w);
		break;
	case Qpointer:
		/* Write-only injectors never took the read-owner ref (see
		 * pointeropen), so don't drop it here. */
		if((c->mode & 3) == OWRITE)
			break;
		qlock(&mouse.q);
		if(decref(&mouse.ref) == 0){
			cursordisable();
		}
		qunlock(&mouse.q);
		break;
	}
}

static long
pointerread(Chan* c, void* a, long n, vlong off)
{
	Pointer mt;
	char buf[1+5*12+1];
	int l;

	USED(&off);
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
		l = snprint(buf, sizeof(buf), "m%11d %11d %11d %11lud ", mt.x, mt.y, mt.b, mt.msec);
		if(l < n)
			n = l;
		memmove(a, buf, n);
		break;
	case Qfingers:
		{
			Finger f;

			qlock(&fq.rq);
			if(waserror()){
				qunlock(&fq.rq);
				nexterror();
			}
			Sleep(&fq.r, fingerready, nil);
			poperror();
			qunlock(&fq.rq);
			lock(&fq.l);
			if(fq.n == 0){
				unlock(&fq.l);
				return 0;
			}
			f = fq.e[fq.rd];
			fq.rd = (fq.rd+1) % Nfinger;
			fq.n--;
			unlock(&fq.l);
			Wakeup(&fq.w);
			l = snprint(buf, sizeof(buf), "f%11d %11d %11d %11d %11lud ", f.id, f.x, f.y, f.on, f.msec);
			if(l < n)
				n = l;
			memmove(a, buf, n);
		}
		break;
	default:
		n=0;
		break;
	}
	return n;
}

static long
pointerwrite(Chan* c, void* va, long n, vlong off)
{
	char *a = va;
	char buf[128];
	int b, x, y;
	Drawcursor cur;

	USED(&off);
	switch((ulong)c->qid.path){
	case Qpointer:
		if(n > sizeof buf-1)
			n = sizeof buf -1;
		memmove(buf, va, n);
		buf[n] = 0;
		x = strtoul(buf+1, &a, 0);
		if(*a == 0)
			error(Eshort);
		y = strtoul(a, &a, 0);
		/*
		 * "m<x> <y> <b>" is a pointer event, buttons and position, as
		 * a mouse would send it (mouseinject).  The host's pointer is
		 * not moved for it: moving it makes the host report a motion
		 * with its own buttons, none, which let go of a button the
		 * event holds (a menu held open, a drag).  "m<x> <y>" alone
		 * moves the pointer (wmlib's "ptr" request), host's and all;
		 * blanks after y, a shell's echo's newline, are not buttons.
		 */
		while(*a == ' ' || *a == '\t' || *a == '\n' || *a == '\r')
			a++;
		if(*a != 0){
			b = strtoul(a, 0, 0);
			mouseinject(b, x, y);
		}else{
			mousetrack(mouse.v.b, x, y, 0);
			setpointer(x, y);
		}
		break;
	case Qfingers:
		{
			int id, on;

			if(n > sizeof buf-1)
				n = sizeof buf -1;
			memmove(buf, va, n);
			buf[n] = 0;
			if(buf[0] != 'f')
				error(Ebadarg);
			id = strtoul(buf+1, &a, 0);
			x = strtoul(a, &a, 0);
			y = strtoul(a, &a, 0);
			if(*a == 0)
				error(Eshort);
			on = strtoul(a, 0, 0);
			qlock(&fq.wq);
			if(waserror()){
				qunlock(&fq.wq);
				nexterror();
			}
			while(!fingerput(id, x, y, on))
				Sleep(&fq.w, fingerroom, nil);
			poperror();
			qunlock(&fq.wq);
		}
		break;
	case Qcursor:
		/* TO DO: perhaps interpret data as an Image */
		/*
		 *  hotx[4] hoty[4] dx[4] dy[4] clr[dx/8 * dy/2] set[dx/8 * dy/2]
		 *  dx must be a multiple of 8; dy must be a multiple of 2.
		 */
		if(n == 0){
			cur.data = nil;
			drawcursor(&cur);
			break;
		}
		if(n < 8)
			error(Eshort);
		cur.hotx = BGLONG((uchar*)va+0*4);
		cur.hoty = BGLONG((uchar*)va+1*4);
		cur.minx = 0;
		cur.miny = 0;
		cur.maxx = BGLONG((uchar*)va+2*4);
		cur.maxy = BGLONG((uchar*)va+3*4);
		if(cur.maxx%8 != 0 || cur.maxy%2 != 0 || n-4*4 != (cur.maxx/8 * cur.maxy))
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

	devinit,
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
