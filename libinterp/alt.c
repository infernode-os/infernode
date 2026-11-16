#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#include "opreg.h"
#define OP(fn)	void fn(OPARGS)
#define W(p)	*((WORD*)(p))

#define CANGET(c)	((c)->size > 0)
#define CANPUT(c)	((c)->buf != H && (c)->size < (c)->buf->len)

extern	OP(isend);
extern	OP(irecv);

/*
 * Count the number of ready channels in an array of channels
 * Set each channel's alt pointer to the owning prog
 */
static int
altmark(Channel *c, Prog *p, char **e)
{
	int nrdy;
	Array *a;
	Channel **ca, **ec;

	nrdy = 0;
	a = (Array*)c;
	ca = (Channel**)a->data;
	ec = ca + a->len;
	while(ca < ec) {
		c = *ca;
		if(c != H) {
			if(c->send->prog || CANGET(c))
				nrdy++;
			if(!cqaddok(&c->recv, p))
				*e = exNomem;
		}
		ca++;
	}

	return nrdy;
}

/*
 * Remove alt references to an array of channels
 */
static void
altunmark(Channel *c, WORD *ptr, Prog *p, int sr, Channel **sel, int dn)
{
	int n;
	Array *a;
	Channel **ca, **ec;

	n = 0;
	a = (Array*)c;
	ca = (Channel**)a->data;
	ec = ca + a->len;
	while(ca < ec) {
		c = *ca;
		if(c != H)
			cqdelp(&c->recv, p);
		if(sr == 1 && *sel == c) {
			W(p->reg.d) = dn;
			p->ptr = ptr + 1;
			ptr[0] = n;
			*sel = nil;
		}
		ca++;
		n++;
	}
}

/*
 * ALT Pass 1 - Count the number of ready channels and mark
 * each channel as ALT by this prog
 */
static int
altrdy(Alt *a, Prog *p)
{
	char *e;
	Type *t;
	int nrdy;
	Channel *c;
	Altc *ac, *eac;

	e = nil;
	nrdy = 0;

	ac = a->ac + a->nsend;
	eac = ac + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		ac++;
		if(c == H) {
			e = exNilref;
			continue;
		}
		t = D2H(c)->t;
		if(t == &Tarray)
			nrdy += altmark(c, p, &e);
		else {
			if(c->send->prog || CANGET(c))
				nrdy++;
			if(!cqaddok(&c->recv, p))
				e = exNomem;	/* undone by altdone below */
		}
	}

	ac = a->ac;
	eac = ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		ac++;
		if(c == H) {
			e = exNilref;
			continue;
		}
		/*
		 * Anywhere on the queue, not only first: behind another
		 * receiver the channel was taken for one this Prog could
		 * send to, and then for one it could receive from (itself,
		 * queued just below): it received from itself, through nil.
		 */
		if(cqhas(c->recv, p)) {
			e = exAlt;
			continue;
		}
		if(c->recv->prog || CANPUT(c))
			nrdy++;
		if(!cqaddok(&c->send, p))
			e = exNomem;
	}

	if(e != nil) {
		altdone(a, p, nil, -1);
		error(e);
	}

	return nrdy;
}

/*
 * ALT Pass 3 - Pull out of an ALT cancelling the channel pointers in each item
 *
 * One of the channels may be on its way out: the alt's table does not
 * count its references, so the last can be dropped while the Prog waits,
 * and freechan's killcomm takes that channel's queues away before it
 * calls altgone.  cqdelp takes a queue that is not there; nothing here
 * looks at one.  (It looked at c->send->prog: a fault inside the
 * collector's lock, which left the collector off for good.)
 */
void
altdone(Alt *a, Prog *p, Channel *sel, int sr)
{
	int n;
	Type *t;
	Channel *c;
	Altc *ac, *eac;

	n = 0;
	ac = a->ac;
	eac = a->ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		if(c != H) {
			cqdelp(&c->send, p);
			if(sr == 0 && c == sel) {
				p->ptr = ac->ptr;
				W(p->reg.d) = n;
				sel = nil;
			}
		}
		ac++;
		n++;
	}

	eac = a->ac + a->nsend + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		if(c != H) {
			t = D2H(c)->t;
			if(t == &Tarray)
				altunmark(c, ac->ptr, p, sr, &sel, n);
			else {
				cqdelp(&c->recv, p);
				if(sr == 1 && c == sel) {
					p->ptr = ac->ptr;
					W(p->reg.d) = n;
					sel = nil;
				}
			}
		}
		ac++;
		n++;
	}
}

/*
 * ALT Pass 2 - Perform the communication on the chosen channel
 */
static int
altcomm(Alt *a, int which)
{
	RPDECL;
	Type *t;
	Array *r;
	int n, an;
	WORD *ptr;
	Altc *ac, *eac;
	Channel *c, **ca, **ec;

	n = 0;
	ac = a->ac;
	eac = ac + a->nsend;
	while(ac < eac) {
		c = ac->c;
		if((c->recv->prog != nil || CANPUT(c)) && which-- == 0) {
			W(R.d) = n;
			R.s = ac->ptr;
			R.d = &c;
			isend(OPCALL);
			return 1;
		}
		ac++;
		n++;
	}

	eac = eac + a->nrecv;
	while(ac < eac) {
		c = ac->c;
		t = D2H(c)->t;
		if(t == &Tarray) {
			an = 0;
			r = (Array*)c;
			ca = (Channel**)r->data;
			ec = ca + r->len;
			while(ca < ec) {
				c = *ca;
				if(c != H && (c->send->prog != nil || CANGET(c)) && which-- == 0) {
					W(R.d) = n;
					R.s = &c;
					ptr = ac->ptr;
					R.d = ptr + 1;
					ptr[0] = an;
					irecv(OPCALL);
					return 1;
				}
				ca++;
				an++;
			}
		}
		else
		if((c->send->prog != nil || CANGET(c)) && which-- == 0) {
			W(R.d) = n;
			R.s = &c;
			R.d = ac->ptr;
			irecv(OPCALL);
			return 1;
		}
		ac++;
		n++;
	}
	return 0;
}

void
altgone(Prog *p)
{
	Alt *a;

	if (p->state == Palt) {
		a = p->reg.s;
		altdone(a, p, nil, -1);
		p->kill = "alt channel hungup";
		addrun(p);
	}
}

void
xecalt(int block)
{
	RPDECL;
	Alt *a;
	Prog *p;
	int nrdy;
	static ulong xrand = 0x20342;

	p = currun();

	a = R.s;
	nrdy = altrdy(a, p);
	if(nrdy == 0) {
		if(block) {
			delrun(Palt);
			p->reg.s = R.s;
			p->reg.d = R.d;
			R.IC = 1;
			R.t = 1;
			return;
		}
		W(R.d) = a->nsend + a->nrecv;
		altdone(a, p, nil, -1);
		return;
	}

	xrand = xrand*1103515245 + 12345;
	if(!altcomm(a, (xrand>>8)%nrdy)) {
		/* altrdy and altcomm disagree: not an arm chosen at random */
		altdone(a, p, nil, -1);
		error(exAlt);
	}
	altdone(a, p, nil, -1);
}
