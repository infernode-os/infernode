/*
 * IP routing table.
 *
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/ip/iproute.c.
 * The NOTICE at that tree's root states "The bulk of the tree is
 * covered by the permissive MIT licence", and this tree's LICENSE
 * already credits Vita Nuova's revisions.
 *
 * In the build (tests/host/baremetal_test.sh compiles all of os/ip),
 * and guarded by tests/host/iproute_test.sh, which extracts the
 * route-range arithmetic and checks it under LP64 on the host. That
 * test landed BEFORE this file was compiled, deliberately: iproute.c is
 * the one file in os/ip with a SILENT WRONG ANSWER failure mode -- a
 * route table that returns the wrong route does not crash, it
 * misroutes -- and it held three separate width bugs under LP64.
 * Getting a test in front of it was worth more than getting it
 * compiling. Keep the test ahead of any change here.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include	"ip.h"

static void	walkadd(Fs*, Route**, Route*);
static void	addnode(Fs*, Route**, Route*);
static void	calcd(Route*);

/* these are used for all instances of IP */
Route*	v4freelist;
Route*	v6freelist;
RWlock	routelock;
ulong	v4routegeneration, v6routegeneration;

enum {
	Maxroutenodes	= 1<<16,	/* of each family: 64 short prefixes, or as many host routes */
};
static int v4nodes, v6nodes;	/* in use, under routelock */

static void
freeroute(Route *r)
{
	Route **l;

	r->left = nil;
	r->right = nil;
	if(r->type & Rv4){
		l = &v4freelist;
		v4nodes--;
	} else {
		l = &v6freelist;
		v6nodes--;
	}
	r->mid = *l;
	*l = r;
}

/*
 * Room for n more nodes of a family?  A route is a node in every hash
 * bucket its range crosses, 1024 of them for any short prefix, and
 * routes are added by whoever is on the link (a router advertisement's
 * prefixes): with no limit the table grew until malloc failed, and
 * allocroute's answer to that is a panic.  A route there is no room
 * for is refused, and said so once.
 */
static int
routeroom(int nodes, int n)
{
	return n >= 0 && n <= Maxroutenodes && nodes <= Maxroutenodes - n;
}

/*
 * A mask is ones and then zeros.  Any other gives a range that is not
 * a prefix, which the tree's comparisons take for contained in ranges
 * it only overlaps: the node goes where lookups do not reach.
 */
static int
routemaskok(uchar *mask, int n)
{
	int i, seenzero;
	uchar m;

	seenzero = 0;
	for(i = 0; i < n; i++){
		m = mask[i];
		if(seenzero){
			if(m != 0)
				return 0;
			continue;
		}
		if(m == 0xff)
			continue;
		seenzero = 1;
		/* a byte of ones then zeros: its complement plus one is a power of two */
		if(((uchar)~m & (uchar)(~m + 1)) != 0)
			return 0;
	}
	return 1;
}

static Route*
allocroute(int type)
{
	Route *r;
	int n;
	Route **l;

	if(type & Rv4){
		n = sizeof(RouteTree) + sizeof(V4route);
		l = &v4freelist;
	} else {
		n = sizeof(RouteTree) + sizeof(V6route);
		l = &v6freelist;
	}

	r = *l;
	if(r != nil){
		*l = r->mid;
	} else {
		r = malloc(n);
		if(r == nil)
			panic("out of routing nodes");
	}
	if(type & Rv4)
		v4nodes++;
	else
		v6nodes++;
	memset(r, 0, n);
	r->type = type;
	r->ifc = nil;
	r->ref = 1;

	return r;
}

static void
addqueue(Route **q, Route *r)
{
	Route *l;

	if(r == nil)
		return;

	l = allocroute(r->type);
	l->mid = *q;
	*q = l;
	l->left = r;
}

/*
 *   compare 2 v6 addresses
 */
static int
lcmp(u32int *a, u32int *b)
{
	int i;

	for(i = 0; i < IPllen; i++){
		if(a[i] > b[i])
			return 1;
		if(a[i] < b[i])
			return -1;
	}
	return 0;
}

/*
 *  compare 2 v4 or v6 ranges
 */
enum
{
	Rpreceeds,
	Rfollows,
	Requals,
	Rcontains,
	Rcontained,
};

static int
rangecompare(Route *a, Route *b)
{
	if(a->type & Rv4){
		if(a->v4.endaddress < b->v4.address)
			return Rpreceeds;

		if(a->v4.address > b->v4.endaddress)
			return Rfollows;

		if(a->v4.address <= b->v4.address
		&& a->v4.endaddress >= b->v4.endaddress){
			if(a->v4.address == b->v4.address
			&& a->v4.endaddress == b->v4.endaddress)
				return Requals;
			return Rcontains;
		}
		return Rcontained;
	}

	if(lcmp(a->v6.endaddress, b->v6.address) < 0)
		return Rpreceeds;

	if(lcmp(a->v6.address, b->v6.endaddress) > 0)
		return Rfollows;

	if(lcmp(a->v6.address, b->v6.address) <= 0
	&& lcmp(a->v6.endaddress, b->v6.endaddress) >= 0){
		if(lcmp(a->v6.address, b->v6.address) == 0
		&& lcmp(a->v6.endaddress, b->v6.endaddress) == 0)
				return Requals;
		return Rcontains;
	}

	return Rcontained;
}

static void
copygate(Route *old, Route *new)
{
	if(new->type & Rv4)
		memmove(old->v4.gate, new->v4.gate, IPv4addrlen);
	else
		memmove(old->v6.gate, new->v6.gate, IPaddrlen);
}

/*
 *  walk down a tree adding nodes back in
 */
static void
walkadd(Fs *f, Route **root, Route *p)
{
	Route *l, *r;

	l = p->left;
	r = p->right;
	p->left = 0;
	p->right = 0;
	addnode(f, root, p);
	if(l)
		walkadd(f, root, l);
	if(r)
		walkadd(f, root, r);
}

/*
 *  calculate depth
 */
static void
calcd(Route *p)
{
	Route *q;
	int d;

	if(p) {
		d = 0;
		q = p->left;
		if(q)
			d = q->depth;
		q = p->right;
		if(q && q->depth > d)
			d = q->depth;
		q = p->mid;
		if(q && q->depth > d)
			d = q->depth;
		p->depth = d+1;
	}
}

/*
 *  balance the tree at the current node
 */
static void
balancetree(Route **cur)
{
	Route *p, *l, *r;
	int dl, dr;

	/*
	 * if left and right are
	 * too out of balance,
	 * rotate tree node
	 */
	p = *cur;
	dl = 0; if(l = p->left) dl = l->depth;
	dr = 0; if(r = p->right) dr = r->depth;

	if(dl > dr+1) {
		p->left = l->right;
		l->right = p;
		*cur = l;
		calcd(p);
		calcd(l);
	} else
	if(dr > dl+1) {
		p->right = r->left;
		r->left = p;
		*cur = r;
		calcd(p);
		calcd(r);
	} else
		calcd(p);
}

/*
 *  add a new node to the tree
 */
static void
addnode(Fs *f, Route **cur, Route *new)
{
	Route *p;

	p = *cur;
	if(p == 0) {
		*cur = new;
		new->depth = 1;
		return;
	}

	switch(rangecompare(new, p)){
	case Rpreceeds:
		addnode(f, &p->left, new);
		break;
	case Rfollows:
		addnode(f, &p->right, new);
		break;
	case Rcontains:
		/*
		 *  if new node is superset
		 *  of tree node,
		 *  replace tree node and
		 *  queue tree node to be
		 *  merged into root.
		 */
		*cur = new;
		new->depth = 1;
		addqueue(&f->queue, p);
		break;
	case Requals:
		/*
		 *  supercede the old entry if the old one isn't
		 *  a local interface.
		 */
		if((p->type & Rifc) == 0){
			p->type = new->type;
			p->ifcid = -1;
			copygate(p, new);
		} else if(new->type & Rifc)
			p->ref++;
		freeroute(new);
		break;
	case Rcontained:
		addnode(f, &p->mid, new);
		break;
	}
	
	balancetree(cur);
}

#define	V4H(a)	((a&0x07ffffff)>>(32-Lroot-5))

/* said once for each family: a table filled from the link fills again */
static void
routefull(char *family)
{
	static int said[2];
	int i;

	i = family[1] == '6';
	if(!said[i]){
		said[i] = 1;
		print("iproute: %s route table is full (%d nodes); further routes are refused\n",
			family, Maxroutenodes);
	}
}

void
v4addroute(Fs *f, char *tag, uchar *a, uchar *mask, uchar *gate, int type)
{
	Route *p;
	u32int sa;
	u32int m;
	u32int ea;
	int h, eh;

	m = nhgetl(mask);
	sa = nhgetl(a) & m;
	ea = sa | ~m;

	if(!routemaskok(mask, IPv4addrlen))
		return;

	/*
	 * One hold of the lock for the whole route.  The nodes come from a
	 * free list the lock guards, so taking one outside it let two adds
	 * take the same node and link it into two trees; a route across
	 * several buckets was in some and not others between holds; and
	 * the generation, which is what tells a conversation its cached
	 * route may be gone, was counted after the lock was let go.
	 */
	eh = V4H(ea);
	wlock(&routelock);
	if(!routeroom(v4nodes, eh - V4H(sa) + 1)){
		wunlock(&routelock);
		routefull("v4");
		return;
	}
	for(h=V4H(sa); h<=eh; h++) {
		p = allocroute(Rv4 | type);
		p->v4.address = sa;
		p->v4.endaddress = ea;
		memmove(p->v4.gate, gate, sizeof(p->v4.gate));
		memmove(p->tag, tag, sizeof(p->tag));

		addnode(f, &f->v4root[h], p);
		while(p = f->queue) {
			f->queue = p->mid;
			walkadd(f, &f->v4root[h], p->left);
			freeroute(p);
		}
	}
	v4routegeneration++;
	wunlock(&routelock);

	ipifcaddroute(f, Rv4, a, mask, gate, type);
}

#define	V6H(a)	(((a)[IPllen-1] & 0x07ffffff)>>(32-Lroot-5))
#define ISDFLT(a, mask, tag) ((ipcmp((a),v6Unspecified)==0) && (ipcmp((mask),v6Unspecified)==0) && (strcmp((tag), "ra")!=0))

void
v6addroute(Fs *f, char *tag, uchar *a, uchar *mask, uchar *gate, int type)
{
	Route *p;
	u32int sa[IPllen], ea[IPllen];
	u32int x, y;
	int h, eh;

	/*
	if(ISDFLT(a, mask, tag))
		f->v6p->cdrouter = -1;
	*/


	for(h = 0; h < IPllen; h++){
		x = nhgetl(a+4*h);
		y = nhgetl(mask+4*h);
		sa[h] = x & y;
		ea[h] = x | ~y;
	}

	if(!routemaskok(mask, IPaddrlen))
		return;

	/* one hold of the lock for the whole route: see v4addroute */
	eh = V6H(ea);
	wlock(&routelock);
	if(!routeroom(v6nodes, eh - V6H(sa) + 1)){
		wunlock(&routelock);
		routefull("v6");
		return;
	}
	for(h = V6H(sa); h <= eh; h++) {
		p = allocroute(type);
		memmove(p->v6.address, sa, IPaddrlen);
		memmove(p->v6.endaddress, ea, IPaddrlen);
		memmove(p->v6.gate, gate, IPaddrlen);
		memmove(p->tag, tag, sizeof(p->tag));

		addnode(f, &f->v6root[h], p);
		while(p = f->queue) {
			f->queue = p->mid;
			walkadd(f, &f->v6root[h], p->left);
			freeroute(p);
		}
	}
	v6routegeneration++;
	wunlock(&routelock);

	ipifcaddroute(f, 0, a, mask, gate, type);
}

Route**
looknode(Route **cur, Route *r)
{
	Route *p;

	for(;;){
		p = *cur;
		if(p == 0)
			return 0;
	
		switch(rangecompare(r, p)){
		case Rcontains:
			return 0;
		case Rpreceeds:
			cur = &p->left;
			break;
		case Rfollows:
			cur = &p->right;
			break;
		case Rcontained:
			cur = &p->mid;
			break;
		case Requals:
			return cur;
		}
	}
}

void
v4delroute(Fs *f, uchar *a, uchar *mask, int dolock)
{
	Route **r, *p;
	Route rt;
	int h, eh;
	u32int m;

	m = nhgetl(mask);
	rt.v4.address = nhgetl(a) & m;
	rt.v4.endaddress = rt.v4.address | ~m;
	rt.type = Rv4;

	eh = V4H(rt.v4.endaddress);
	if(dolock)
		wlock(&routelock);
	for(h=V4H(rt.v4.address); h<=eh; h++) {
		r = looknode(&f->v4root[h], &rt);
		if(r) {
			p = *r;
			if(--(p->ref) == 0){
				*r = 0;
				addqueue(&f->queue, p->left);
				addqueue(&f->queue, p->mid);
				addqueue(&f->queue, p->right);
				freeroute(p);
				while(p = f->queue) {
					f->queue = p->mid;
					walkadd(f, &f->v4root[h], p->left);
					freeroute(p);
				}
			}
		}
	}
	/* before the lock is let go: a lookup holding it must not find the old count and a freed route */
	v4routegeneration++;
	if(dolock)
		wunlock(&routelock);

	ipifcremroute(f, Rv4, a, mask);
}

void
v6delroute(Fs *f, uchar *a, uchar *mask, int dolock)
{
	Route **r, *p;
	Route rt;
	int h, eh;
	u32int x, y;

	for(h = 0; h < IPllen; h++){
		x = nhgetl(a+4*h);
		y = nhgetl(mask+4*h);
		rt.v6.address[h] = x & y;
		rt.v6.endaddress[h] = x | ~y;
	}
	rt.type = 0;

	eh = V6H(rt.v6.endaddress);
	if(dolock)
		wlock(&routelock);
	for(h=V6H(rt.v6.address); h<=eh; h++) {
		r = looknode(&f->v6root[h], &rt);
		if(r) {
			p = *r;
			if(--(p->ref) == 0){
				*r = 0;
				addqueue(&f->queue, p->left);
				addqueue(&f->queue, p->mid);
				addqueue(&f->queue, p->right);
				freeroute(p);
				while(p = f->queue) {
					f->queue = p->mid;
					walkadd(f, &f->v6root[h], p->left);
					freeroute(p);
				}
			}
		}
	}
	v6routegeneration++;
	if(dolock)
		wunlock(&routelock);

	ipifcremroute(f, 0, a, mask);
}

Route*
v4lookup(Fs *f, uchar *a, Conv *c)
{
	Route *p, *q;
	u32int la;
	uchar gate[IPaddrlen];
	Ipifc *ifc;

	la = nhgetl(a);
	q = nil;
	rlock(&routelock);
	/*
	 * The cache is one route for the conversation, of whichever family
	 * it last sent to, and the two generations are counted apart: a
	 * route of the other family whose count happens to be the same is
	 * not this family's route (a v6 node read as v4 is a gateway of
	 * address bytes; a v4 node read as v6 is read past its end).
	 */
	if(c != nil && c->r != nil && (c->r->type & Rv4) != 0 && c->rgen == v4routegeneration){
		q = c->r;
		goto resolve;
	}
	for(p=f->v4root[V4H(la)]; p;)
		if(la >= p->v4.address) {
			if(la <= p->v4.endaddress) {
				q = p;
				p = p->mid;
			} else
				p = p->right;
		} else
			p = p->left;


resolve:
	if(q != nil){
		ifc = q->ifc;
		if(ifc != nil && canrlock(&ifc->rwl)){
			if(ifc->ifcid == q->ifcid){
				runlock(&ifc->rwl);
				goto resolved;
			}
			runlock(&ifc->rwl);
		}
		if(q->type & Rifc) {
			hnputl(gate+IPv4off, q->v4.address);
			memmove(gate, v4prefix, IPv4off);
		} else
			v4tov6(gate, q->v4.gate);
		ifc = findipifc(f, gate, q->type);
		if(ifc == nil)
			q = nil;
		else {
			q->ifc = ifc;
			q->ifcid = ifc->ifcid;
			runlock(&ifc->rwl);
		}
	}

resolved:
	if(c != nil){
		c->r = q;
		c->rgen = v4routegeneration;
	}

	runlock(&routelock);
	return q;
}

Route*
v6lookup(Fs *f, uchar *a, Conv *c)
{
	Route *p, *q;
	u32int la[IPllen];
	int h;
	u32int x, y;
	uchar gate[IPaddrlen];
	Ipifc *ifc;

	if(memcmp(a, v4prefix, IPv4off) == 0){
		q = v4lookup(f, a+IPv4off, c);
		if(q != nil)
			return q;
	}

	for(h = 0; h < IPllen; h++)
		la[h] = nhgetl(a+4*h);

	q = 0;
	rlock(&routelock);
	if(c != nil && c->r != nil && (c->r->type & Rv4) == 0 && c->rgen == v6routegeneration){
		q = c->r;
		goto resolve;
	}
	for(p=f->v6root[V6H(la)]; p;){
		for(h = 0; h < IPllen; h++){
			x = la[h];
			y = p->v6.address[h];
			if(x == y)
				continue;
			if(x < y){
				p = p->left;
				goto next;
			}
			break;
		}
		for(h = 0; h < IPllen; h++){
			x = la[h];
			y = p->v6.endaddress[h];
			if(x == y)
				continue;
			if(x > y){
				p = p->right;
				goto next;
			}
			break;
		}
		q = p;
		p = p->mid;
next:		;
	}


resolve:
	if(q != nil){
		ifc = q->ifc;
		if(ifc != nil && canrlock(&ifc->rwl)){
			if(ifc->ifcid == q->ifcid){
				runlock(&ifc->rwl);
				goto resolved;
			}
			runlock(&ifc->rwl);
		}
		if(q->type & Rifc) {
			for(h = 0; h < IPllen; h++)
				hnputl(gate+4*h, q->v6.address[h]);
			ifc = findipifc(f, gate, q->type);
		} else
			ifc = findipifc(f, q->v6.gate, q->type);
		if(ifc == nil)
			q = nil;
		else {
			q->ifc = ifc;
			q->ifcid = ifc->ifcid;
			runlock(&ifc->rwl);
		}
	}

resolved:
	if(c != nil){
		c->r = q;
		c->rgen = v6routegeneration;
	}
	runlock(&routelock);
	return q;
}

void
routetype(int type, char *p)
{
	memset(p, ' ', 4);
	p[4] = 0;
	if(type & Rv4)
		*p++ = '4';
	else
		*p++ = '6';
	if(type & Rifc)
		*p++ = 'i';
	if(type & Runi)
		*p++ = 'u';
	else if(type & Rbcast)
		*p++ = 'b';
	else if(type & Rmulti)
		*p++ = 'm';
	if(type & Rptpt)
		*p = 'p';
}

char *rformat = "%-15I %-4M %-15I %4.4s %4.4s %3s\n";

void
convroute(Route *r, uchar *addr, uchar *mask, uchar *gate, char *t, int *nifc)
{
	int i;

	if(r->type & Rv4){
		memmove(addr, v4prefix, IPv4off);
		hnputl(addr+IPv4off, r->v4.address);
		memset(mask, 0xff, IPv4off);
		hnputl(mask+IPv4off, ~(r->v4.endaddress ^ r->v4.address));
		memmove(gate, v4prefix, IPv4off);
		memmove(gate+IPv4off, r->v4.gate, IPv4addrlen);
	} else {
		for(i = 0; i < IPllen; i++){
			hnputl(addr + 4*i, r->v6.address[i]);
			hnputl(mask + 4*i, ~(r->v6.endaddress[i] ^ r->v6.address[i]));
		}
		memmove(gate, r->v6.gate, IPaddrlen);
	}

	routetype(r->type, t);

	if(r->ifc)
		*nifc = r->ifc->conv->x;
	else
		*nifc = -1;
}

/*
 *  this code is not in rr to reduce stack size
 */
static void
sprintroute(Route *r, Routewalk *rw)
{
	int nifc, n;
	char t[5], *iname, ifbuf[5];
	uchar addr[IPaddrlen], mask[IPaddrlen], gate[IPaddrlen];
	char *p;

	convroute(r, addr, mask, gate, t, &nifc);
	iname = "-";
	if(nifc != -1) {
		iname = ifbuf;
		snprint(ifbuf, sizeof ifbuf, "%d", nifc);
	}
	p = seprint(rw->p, rw->e, rformat, addr, mask, gate, t, r->tag, iname);
	if(rw->o < 0){
		n = p - rw->p;
		if(n > -rw->o){
			memmove(rw->p, rw->p-rw->o, n+rw->o);
			rw->p = p + rw->o;
		}
		rw->o += n;
	} else
		rw->p = p;
}

/*
 *  recurse descending tree, applying the function in Routewalk
 */
static int
rr(Route *r, Routewalk *rw)
{
	int h;

	if(rw->e <= rw->p)
		return 0;
	if(r == nil)
		return 1;

	if(rr(r->left, rw) == 0)
		return 0;

	if(r->type & Rv4)
		h = V4H(r->v4.address);
	else
		h = V6H(r->v6.address);

	if(h == rw->h)
		rw->walk(r, rw);

	if(rr(r->mid, rw) == 0)
		return 0;

	return rr(r->right, rw);
}

void
ipwalkroutes(Fs *f, Routewalk *rw)
{
	rlock(&routelock);
	if(rw->e > rw->p) {
		for(rw->h = 0; rw->h < nelem(f->v4root); rw->h++)
			if(rr(f->v4root[rw->h], rw) == 0)
				break;
	}
	if(rw->e > rw->p) {
		for(rw->h = 0; rw->h < nelem(f->v6root); rw->h++)
			if(rr(f->v6root[rw->h], rw) == 0)
				break;
	}
	runlock(&routelock);
}

long
routeread(Fs *f, char *p, ulong offset, int n)
{
	Routewalk rw;

	rw.p = p;
	rw.e = p+n;
	rw.o = -offset;
	rw.walk = sprintroute;

	ipwalkroutes(f, &rw);

	return rw.p - p;
}

/*
 *  this code is not in routeflush to reduce stack size
 */
void
delroute(Fs *f, Route *r, int dolock)
{
	uchar addr[IPaddrlen];
	uchar mask[IPaddrlen];
	uchar gate[IPaddrlen];
	char t[5];
	int nifc;

	convroute(r, addr, mask, gate, t, &nifc);
	if(r->type & Rv4)
		v4delroute(f, addr+IPv4off, mask+IPv4off, dolock);
	else
		v6delroute(f, addr, mask, dolock);
}

/*
 *  recurse until one route is deleted
 *    returns 0 if nothing is deleted, 1 otherwise
 */
int
routeflush(Fs *f, Route *r, char *tag)
{
	if(r == nil)
		return 0;
	if(routeflush(f, r->mid, tag))
		return 1;
	if(routeflush(f, r->left, tag))
		return 1;
	if(routeflush(f, r->right, tag))
		return 1;
	if((r->type & Rifc) == 0){
		if(tag == nil || strncmp(tag, r->tag, sizeof(r->tag)) == 0){
			delroute(f, r, 0);
			return 1;
		}
	}
	return 0;
}

long
routewrite(Fs *f, Chan *c, char *p, int n)
{
	int h, changed;
	char *tag;
	Cmdbuf *cb;
	uchar addr[IPaddrlen];
	uchar mask[IPaddrlen];
	uchar gate[IPaddrlen];
	IPaux *a, *na;

	cb = parsecmd(p, n);
	if(waserror()){
		free(cb);
		nexterror();
	}

	if(cb->nf < 1)
		error(Ebadarg);		/* an empty write has no f[0] to compare */

	if(strcmp(cb->f[0], "flush") == 0){
		tag = cb->f[1];
		for(h = 0; h < nelem(f->v4root); h++)
			for(changed = 1; changed;){
				wlock(&routelock);
				changed = routeflush(f, f->v4root[h], tag);
				wunlock(&routelock);
			}
		for(h = 0; h < nelem(f->v6root); h++)
			for(changed = 1; changed;){
				wlock(&routelock);
				changed = routeflush(f, f->v6root[h], tag);
				wunlock(&routelock);
			}
	} else if(strcmp(cb->f[0], "remove") == 0){
		if(cb->nf < 3)
			error(Ebadarg);
		parseip(addr, cb->f[1]);
		parseipmask(mask, cb->f[2]);
		if(memcmp(addr, v4prefix, IPv4off) == 0)
			v4delroute(f, addr+IPv4off, mask+IPv4off, 1);
		else
			v6delroute(f, addr, mask, 1);
	} else if(strcmp(cb->f[0], "add") == 0){
		if(cb->nf < 4)
			error(Ebadarg);
		parseip(addr, cb->f[1]);
		parseipmask(mask, cb->f[2]);
		parseip(gate, cb->f[3]);
		if(!routemaskok(mask, IPaddrlen))
			error(Ebadarg);
		tag = "none";
		if(c != nil){
			a = c->aux;
			tag = a->tag;
		}
		if(memcmp(addr, v4prefix, IPv4off) == 0)
			v4addroute(f, tag, addr+IPv4off, mask+IPv4off, gate+IPv4off, 0);
		else
			v6addroute(f, tag, addr, mask, gate, 0);
	} else if(strcmp(cb->f[0], "tag") == 0) {
		if(cb->nf < 2 || c == nil)
			error(Ebadarg);

		a = c->aux;
		na = newipaux(a->owner, cb->f[1]);
		c->aux = na;
		free(a);
	}

	poperror();
	free(cb);
	return n;
}
