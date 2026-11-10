/*
 *  devssl - secure sockets layer
 */
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	"mp.h"
#include	"libsec.h"

enum
{
	Minsecret=	32,	/* bytes of secret each way, at the least */
	Gcmkeylen=	32,
	Gcmivlen=	12,
	Gcmtaglen=	16,
	Maxrecord=	(1<<15) - 1,	/* a record's length, as its header has it */
	Maxmid=	0xFFFFFFFFUL,	/* records each way before the connection must end */
};

typedef struct OneWay OneWay;
struct OneWay
{
	QLock	q;
	QLock	ctlq;
	QLock	wq;		/* out only: one write's records together */

	void	*state;		/* encryption state */
	int	slen;			/* secret data length */
	uchar	*secret;	/* secret */
	ulong	mid;		/* message id */
	uchar	iv[Gcmivlen];	/* aes_256_gcm: the nonce for record 0 */
};

enum
{
	/* connection states */
	Sincomplete=	0,
	Sclear=		1,
	Sdigesting=	4,	/* hmac_sha384 */
	Saead=		8,	/* aes_256_gcm */
};

typedef struct Dstate Dstate;
struct Dstate
{
	Chan	*c;			/* io channel */
	uchar	state;		/* state of connection */
	int	ref;			/* serialized by dslock for atomic destroy */

	ushort	diglen;		/* bytes a record adds to its data: MAC or tag */

	/* for SSL format */
	int	max;			/* maximum data per record */

	/* input side */
	OneWay	in;
	Block	*processed;
	Block	*unprocessed;

	/* output side */
	OneWay	out;

	/* protections */
	char*	user;
	int	perm;
};

enum
{
	Maxdmsg=	1<<16,
	Maxdstate=	1<<10,
};

Lock	dslock;
int	dshiwat;
int	maxdstate = 20;
Dstate** dstate;

enum{
	Qtopdir		= 1,	/* top level directory */
	Qclonus,
	Qconvdir,			/* directory for a conversation */
	Qdata,
	Qctl,
	Qsecretin,
	Qsecretout,
	Qencalgs,
	Qhashalgs,
	Qlower			/* the name of the channel pushed under it */
};

#define TYPE(x) 	((ulong)(x).path & 0xf)
#define CONV(x) 	(((ulong)(x).path >> 4)&(Maxdstate-1))
#define QID(c, y) 	(((c)<<4) | (y))

static char*	encalgs;
static char*	hashalgs;

void producerand(void);

static void alglistinit(void);
static void	ensure(Dstate*, Block**, int);
static void	consume(Block**, uchar*, int);
static void	setsecret(OneWay*, uchar*, int);
static Block*	sealb(Dstate*, Block*);
static Block*	openb(Dstate*, Block*, int);
static Block*	digestb(Dstate*, Block*, int);
static void	checkdigestb(Dstate*, Block*);
static void	freesecret(OneWay*);
static Chan*	buftochan(char*);
static void	sslhangup(Dstate*);
static void dsclone(Chan *c);
static void	dsnew(Chan *c, Dstate **);

static int
sslgen(Chan *c, char *dname, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;
	Dstate *ds;
	char *p, *nm;

	USED(dname);
	USED(nd);
	USED(d);
	q.type = QTFILE;
	q.vers = 0;
	if(s == DEVDOTDOT){
		q.path = QID(0, Qtopdir);
		q.type = QTDIR;
		devdir(c, q, "#D", 0, eve, 0555, dp);
		return 1;
	}
	switch(TYPE(c->qid)) {
	case Qtopdir:
		if(s < dshiwat) {
			q.path = QID(s, Qconvdir);
			q.type = QTDIR;
			ds = dstate[s];
			if(ds != 0)
 				nm = ds->user;
 			else
 				nm = eve;
			snprint(up->genbuf, sizeof(up->genbuf), "%d", s);
			devdir(c, q, up->genbuf, 0, nm, DMDIR|0555, dp);
			return 1;
		}
		if(s > dshiwat)
			return -1;
		/* fall through */
	case Qclonus:
		q.path = QID(0, Qclonus);
		devdir(c, q, "clone", 0, eve, 0666, dp);
		return 1;
	case Qconvdir:
		ds = dstate[CONV(c->qid)];
		if(ds != 0)
			nm = ds->user;
		else
			nm = eve;
		switch(s) {
		default:
			return -1;
		case 0:
			q.path = QID(CONV(c->qid), Qctl);
			p = "ctl";
			break;
		case 1:
			q.path = QID(CONV(c->qid), Qdata);
			p = "data";
			break;
		case 2:
			q.path = QID(CONV(c->qid), Qsecretin);
			p = "secretin";
			break;
		case 3:
			q.path = QID(CONV(c->qid), Qsecretout);
			p = "secretout";
			break;
		case 4:
			q.path = QID(CONV(c->qid), Qencalgs);
			p = "encalgs";
			break;
		case 5:
			q.path = QID(CONV(c->qid), Qhashalgs);
			p = "hashalgs";
			break;
		case 6:
			q.path = QID(CONV(c->qid), Qlower);
			devdir(c, q, "lower", 0, nm, 0444, dp);
			return 1;
		}
		devdir(c, q, p, 0, nm, 0660, dp);
		return 1;
	}
	return -1;
}

static void
sslinit(void)
{
	if((dstate = malloc(sizeof(Dstate*) * maxdstate)) == 0)
		panic("sslinit");
	alglistinit();
}

static Chan *
sslattach(char *spec)
{
	Chan *c;

	c = devattach('D', spec);
	c->qid.path = QID(0, Qtopdir);
	c->qid.vers = 0;
	c->qid.type = QTDIR;
	return c;
}

static Walkqid*
sslwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, 0, 0, sslgen);
}

static int
sslstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, 0, 0, sslgen);
}

static Chan*
sslopen(Chan *c, int omode)
{
	Dstate *s, **pp;

	switch(TYPE(c->qid)) {
	default:
		panic("sslopen");
	case Qtopdir:
	case Qconvdir:
		if(omode != OREAD)
			error(Eperm);
		break;
	case Qclonus:
		dsclone(c);
		break;
	case Qctl:
	case Qdata:
	case Qsecretin:
	case Qsecretout:
		if(waserror()) {
			unlock(&dslock);
			nexterror();
		}
		lock(&dslock);
		pp = &dstate[CONV(c->qid)];
		s = *pp;
		if(s == 0)
			dsnew(c, pp);
		else {
			devpermcheck(s->user, s->perm, omode);
			s->ref++;
		}
		unlock(&dslock);
		poperror();
		break;
	case Qencalgs:
	case Qhashalgs:
	case Qlower:
		if(omode != OREAD)
			error(Eperm);
		break;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static int
sslwstat(Chan *c, uchar *db, int n)
{
	Dir *dir;
	Dstate *s;
	int m;

	s = dstate[CONV(c->qid)];
	if(s == 0)
		error(Ebadusefd);
	if(strcmp(s->user, up->env->user) != 0)
		error(Eperm);

	dir = smalloc(sizeof(Dir)+n);
	m = convM2D(db, n, &dir[0], (char*)&dir[1]);
	if(m == 0){
		free(dir);
		error(Eshortstat);
	}

	if(!emptystr(dir->uid))
		kstrdup(&s->user, dir->uid);
	if(dir->mode != ~0UL)
		s->perm = dir->mode;

	free(dir);
	return m;
}

static void
sslclose(Chan *c)
{
	Dstate *s;

	switch(TYPE(c->qid)) {
	case Qctl:
	case Qdata:
	case Qsecretin:
	case Qsecretout:
		if((c->flag & COPEN) == 0)
			break;

		s = dstate[CONV(c->qid)];
		if(s == 0)
			break;

		lock(&dslock);
		if(--s->ref > 0) {
			unlock(&dslock);
			break;
		}
		dstate[CONV(c->qid)] = 0;
		unlock(&dslock);

		sslhangup(s);
		if(s->c)
			cclose(s->c);
		free(s->user);
		freesecret(&s->in);
		freesecret(&s->out);
		free(s);
	}
}

/*
 *  make sure we have at least 'n' bytes in list 'l'
 */
static void
ensure(Dstate *s, Block **l, int n)
{
	int sofar, i;
	Block *b, *bl;

	sofar = 0;
	for(b = *l; b; b = b->next){
		sofar += BLEN(b);
		if(sofar >= n)
			return;
		l = &b->next;
	}

	while(sofar < n){
		bl = devtab[s->c->type]->bread(s->c, Maxdmsg, 0);
		if(bl == 0)
			error(Ehungup);
		*l = bl;
		i = 0;
		for(b = bl; b; b = b->next){
			i += BLEN(b);
			l = &b->next;
		}
		if(i == 0)
			error(Ehungup);

		sofar += i;
	}
}

/*
 *  copy 'n' bytes from 'l' into 'p' and free
 *  the bytes in 'l'
 */
static void
consume(Block **l, uchar *p, int n)
{
	Block *b;
	int i;

	for(; *l && n > 0; n -= i){
		b = *l;
		i = BLEN(b);
		if(i > n)
			i = n;
		memmove(p, b->rp, i);
		b->rp += i;
		p += i;
		if(BLEN(b) < 0)
			panic("consume");
		if(BLEN(b))
			break;
		*l = b->next;
		freeb(b);
	}
}

/*
 *  remove at most n bytes from the queue, if discard is set
 *  dump the remainder
 */
static Block*
qtake(Block **l, int n, int discard)
{
	Block *nb, *b, *first;
	int i;

	first = *l;
	for(b = first; b; b = b->next){
		i = BLEN(b);
		if(i == n){
			if(discard){
				freeblist(b->next);
				*l = 0;
			} else
				*l = b->next;
			b->next = 0;
			return first;
		} else if(i > n){
			i -= n;
			if(discard){
				freeblist(b->next);
				*l = 0;
			} else {
				nb = allocb(i);
				memmove(nb->wp, b->rp+n, i);
				nb->wp += i;
				nb->next = b->next;
				*l = nb;
			}
			b->wp -= i;
			b->next = 0;
			if(BLEN(b) < 0)
				panic("qtake");
			return first;
		} else
			n -= i;
		if(BLEN(b) < 0)
			panic("qtake");
	}
	*l = 0;
	return first;
}

static Block*
sslbread(Chan *c, long n, ulong offset)
{
	volatile struct { Dstate *s; } s;
	volatile struct { int nc; } nc;
	Block *b;
	uchar count[2];
	int len;

	USED(offset);
	s.s = dstate[CONV(c->qid)];
	if(s.s == 0)
		panic("sslbread");
	if(s.s->state == Sincomplete)
		error(Ebadusefd);

	nc.nc = 0;
	if(waserror()){
		qunlock(&s.s->in.q);
		if(strcmp(up->env->errstr, "interrupted") == 0){
			if(nc.nc > 0){
				b = allocb(nc.nc);
				memmove(b->wp, count, nc.nc);
				b->wp += nc.nc;
				b->next = s.s->unprocessed;
				s.s->unprocessed = b;
			}
		} else
			sslhangup(s.s);
		nexterror();
	}
	qlock(&s.s->in.q);

	if(s.s->processed == 0){
		/* read in the whole message */
		ensure(s.s, &s.s->unprocessed, 2);

		consume(&s.s->unprocessed, count, 2);
		nc.nc += 2;
		/* a padded (three-byte) header is SSL 2's block ciphers, none of them here */
		if((count[0] & 0x80) == 0)
			error("ssl record with a padded header");
		len = ((count[0] & 0x7f)<<8) | count[1];
		ensure(s.s, &s.s->unprocessed, len);
		nc.nc = 0;

		/* put extra on unprocessed queue */
		s.s->processed = qtake(&s.s->unprocessed, len, 0);

		if(waserror()){
			qunlock(&s.s->in.ctlq);
			nexterror();
		}
		qlock(&s.s->in.ctlq);
		if(s.s->state != Sclear && s.s->in.mid >= Maxmid)
			error("ssl: too many records on one key");
		switch(s.s->state){
		case Sdigesting:
			s.s->processed = pullupblock(s.s->processed, s.s->diglen);
			if(s.s->processed == 0)
				error("ssl message too short");
			checkdigestb(s.s, s.s->processed);
			s.s->processed->rp += s.s->diglen;
			break;
		case Saead:
			s.s->processed = openb(s.s, s.s->processed, len);
			break;
		}
		s.s->in.mid++;
		qunlock(&s.s->in.ctlq);
		poperror();
	}

	/* return at most what was asked for */
	b = qtake(&s.s->processed, n, 0);

	qunlock(&s.s->in.q);
	poperror();

	return b;
}

static long
sslread(Chan *c, void *a, long n, vlong offset)
{
	volatile struct { Block *b; } b;
	Block *nb;
	uchar *va;
	int i;
	char buf[128];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, sslgen);

	switch(TYPE(c->qid)) {
	default:
		error(Ebadusefd);
	case Qctl:
		sprint(buf, "%ld", CONV(c->qid));
		return readstr(offset, a, n, buf);
	case Qdata:
		b.b = sslbread(c, n, offset);
		break;
	case Qencalgs:
		return readstr(offset, a, n, encalgs);
	case Qhashalgs:
		return readstr(offset, a, n, hashalgs);
	case Qlower:
		/*
		 * the channel the conversation was pushed onto (its fd ctl):
		 * a mount's source in a name space is the conversation's
		 * data file, and this is how a reader of /prog/n/ns finds
		 * the connection under it (/net/tcp/3/data)
		 */
		{
			Dstate *ds;
			char nm[256];

			/* copied under dslock: a close takes the
			 * conversation out of dstate under it, and
			 * frees it, its channel too, after */
			nm[0] = 0;
			lock(&dslock);
			ds = dstate[CONV(c->qid)];
			if(ds != 0 && ds->c != 0)
				snprint(nm, sizeof(nm), "%s", c2name(ds->c));
			unlock(&dslock);
			return readstr(offset, a, n, nm);
		}
	}

	n = 0;
	va = a;
	for(nb = b.b; nb; nb = nb->next){
		i = BLEN(nb);
		memmove(va+n, nb->rp, i);
		n += i;
	}

	freeblist(b.b);

	return n;
}

/*
 *  use SSL record format: a two-byte header (0x80 | length), then the
 *  MAC and the data (hmac_sha384), or the data sealed and its tag
 *  (aes_256_gcm)
 */
static long
sslbwrite(Chan *c, Block *b, ulong offset)
{
	volatile struct { Dstate *s; } s;
	volatile struct { Block *b; } bb;
	volatile struct { int begun; } r;
	Block *nb;
	int h, n, m, rv;
	uchar *p;

	bb.b = b;
	s.s = dstate[CONV(c->qid)];
	if(s.s == 0)
		panic("sslbwrite");
	if(s.s->state == Sincomplete){
		freeb(b);
		error(Ebadusefd);
	}

	/*
	 * A record begun and not sent whole leaves the connection out of
	 * step: its sequence number and the cipher's state advanced, or
	 * part of it on the wire.  Only then is it hung up.  An error
	 * between records leaves the stream at a record's end, and the
	 * connection goes on.
	 */
	r.begun = 0;
	if(waserror()){
		qunlock(&s.s->out.q);
		if(bb.b)
			freeb(bb.b);
		if(r.begun)
			sslhangup(s.s);
		nexterror();
	}
	qlock(&s.s->out.q);

	rv = 0;
	while(bb.b){
		/*
		 * An interrupt pending (a Prog killed in a 9P call over this
		 * connection, whose flush comes here) is raised now, before
		 * the record is begun: raised by the host write's osenter, it
		 * hung up a connection every other user of the mount needed.
		 */
		osenter();
		osleave();
		r.begun = 1;
		if(s.s->state != Sclear && s.s->out.mid >= Maxmid)
			error("ssl: too many records on one key");
		m = n = BLEN(bb.b);
		h = 2;
		if(s.s->state == Sdigesting)
			h += s.s->diglen;

		/* trim to maximum record size */
		if(m > s.s->max)
			m = s.s->max;

		rv += m;
		if(m != n || s.s->state == Saead){
			/* room for the header and the tag the record will have */
			nb = allocb(m + h + s.s->diglen);
			memmove(nb->wp + h, bb.b->rp, m);
			nb->wp += m + h;
			bb.b->rp += m;
			if(BLEN(bb.b) == 0){
				freeb(bb.b);
				bb.b = 0;
			}
		} else {
			/* add header space */
			nb = padblock(bb.b, h);
			bb.b = 0;
		}
		m += s.s->diglen;

		/* SSLv2 style count */
		p = nb->rp;
		p[0] = (m>>8) | 0x80;
		p[1] = m;
		offset = 2;

		switch(s.s->state){
		case Sdigesting:
			nb = digestb(s.s, nb, offset);
			break;
		case Saead:
			nb = sealb(s.s, nb);
			break;
		}

		s.s->out.mid++;

		m = BLEN(nb);
		devtab[s.s->c->type]->bwrite(s.s->c, nb, s.s->c->offset);
		s.s->c->offset += m;
		r.begun = 0;
	}
	qunlock(&s.s->out.q);
	poperror();

	return rv;
}

static void
setsecret(OneWay *w, uchar *secret, int n)
{
	uchar *newsecret;

	newsecret = mallocz(n, 0);
	if(newsecret == nil)
		error(Enomem);
	memmove(newsecret, secret, n);
	if(w->secret != nil){
		secureZero(w->secret, w->slen);
		free(w->secret);
	}
	w->secret = newsecret;
	w->slen = n;
}

static void
freestate(OneWay *w)
{
	if(w->state != nil){
		secureZero(w->state, sizeof(AESGCMstate));
		free(w->state);
		w->state = nil;
	}
	secureZero(w->iv, sizeof(w->iv));
}

static void
freesecret(OneWay *w)
{
	if(w->secret != nil){
		secureZero(w->secret, w->slen);
		free(w->secret);
		w->secret = nil;
	}
	w->slen = 0;
	freestate(w);
}

/*
 * aes_256_gcm's key and nonce from a direction's secret, by HKDF
 * (RFC 5869) with SHA-384: PRK = HMAC(0^48, secret), and the key and
 * the nonce of record 0 the first 32 and next 12 bytes of
 * HMAC(PRK, info || 1).  Record n's nonce is that nonce with n,
 * big-endian, exclusive-ored into its last eight bytes, as TLS 1.3's.
 */
static char gcminfo[] = "infernode ssl aes_256_gcm";

static void
initGCMkey(OneWay *w)
{
	uchar salt[SHA384dlen], prk[SHA384dlen], okm[SHA384dlen], info[sizeof(gcminfo)];
	int n;

	freestate(w);
	w->state = malloc(sizeof(AESGCMstate));
	if(w->state == nil)
		error(Enomem);
	memset(salt, 0, sizeof(salt));
	hmac_sha384(w->secret, w->slen, salt, sizeof(salt), prk, nil);
	n = strlen(gcminfo);
	memmove(info, gcminfo, n);
	info[n++] = 1;
	hmac_sha384(info, n, prk, sizeof(prk), okm, nil);
	setupAESGCMstate(w->state, okm, Gcmkeylen, okm+Gcmkeylen, Gcmivlen);
	memmove(w->iv, okm+Gcmkeylen, Gcmivlen);
	secureZero(prk, sizeof(prk));
	secureZero(okm, sizeof(okm));
}

/*
 * What a record may be protected by, each alone: hmac_sha384,
 * HMAC-SHA-384 (FIPS 198-1) keyed by the secret, of the record and its
 * number, the data sent clear; aes_256_gcm, AES-256 in Galois/Counter
 * Mode (SP 800-38D), the data sealed, the header authenticated with
 * them.  Both are CNSA's, and nothing else is offered.
 */
typedef struct Alg Alg;
struct Alg
{
	char	*name;
	int	state;
	int	diglen;
};

static Alg hashtab[] =
{
	{ "hmac_sha384", Sdigesting, SHA384dlen, },
	{ 0 }
};

static Alg encrypttab[] =
{
	{ "aes_256_gcm", Saead, Gcmtaglen, },
	{ 0 }
};

static Alg*
lookalg(Alg *tab, char *p)
{
	for(; tab->name; tab++)
		if(strcmp(p, tab->name) == 0)
			return tab;
	return nil;
}

static void
alglistinit(void)
{
	Alg *h, *e;
	int n;

	n = 1;
	for(e = encrypttab; e->name != nil; e++)
		n += strlen(e->name) + 1;
	encalgs = malloc(n);
	if(encalgs == nil)
		panic("sslinit");
	n = 0;
	for(e = encrypttab; e->name != nil; e++){
		strcpy(encalgs+n, e->name);
		n += strlen(e->name);
		if(e[1].name == nil)
			break;
		encalgs[n++] = ' ';
	}
	encalgs[n] = 0;

	n = 1;
	for(h = hashtab; h->name != nil; h++)
		n += strlen(h->name) + 1;
	hashalgs = malloc(n);
	if(hashalgs == nil)
		panic("sslinit");
	n = 0;
	for(h = hashtab; h->name != nil; h++){
		strcpy(hashalgs+n, h->name);
		n += strlen(h->name);
		if(h[1].name == nil)
			break;
		hashalgs[n++] = ' ';
	}
	hashalgs[n] = 0;
}

static long
sslwrite(Chan *c, void *a, long n, vlong offset)
{
	volatile struct { Dstate *s; } s;
	volatile struct { Block *b; } b;
	int m, t;
	char *p, *e, buf[32];
	uchar *x;
	Alg *al;

	s.s = dstate[CONV(c->qid)];
	if(s.s == 0)
		panic("sslwrite");

	t = TYPE(c->qid);
	if(t == Qdata){
		if(s.s->state == Sincomplete)
			error(Ebadusefd);
	
		/*
		 * A write longer than max goes as several sslbwrites, each
		 * taking out.q alone: two processes writing at once (exportfs's
		 * workers replying) interleaved their records, and the reader
		 * took one message's tail for another's head.  9P messages
		 * past 32K met it: replies to the wrong tags, then a wedged
		 * mount.  wq keeps one write's records together.
		 */
		qlock(&s.s->out.wq);
		if(waserror()){
			qunlock(&s.s->out.wq);
			nexterror();
		}
		p = a;
		e = p + n;
		do {
			m = e - p;
			if(m > s.s->max)
				m = s.s->max;
	
			b.b = allocb(m);
			memmove(b.b->wp, p, m);
			b.b->wp += m;

			sslbwrite(c, b.b, offset);

			p += m;
		} while(p < e);
		poperror();
		qunlock(&s.s->out.wq);
		return n;
	}

	/* mutex with operations using what we're about to change */
	if(waserror()){
		qunlock(&s.s->in.ctlq);
		qunlock(&s.s->out.q);
		nexterror();
	}
	qlock(&s.s->in.ctlq);
	qlock(&s.s->out.q);

	switch(t){
	default:
		panic("sslwrite");
	case Qsecretin:
		setsecret(&s.s->in, a, n);
		goto out;
	case Qsecretout:
		setsecret(&s.s->out, a, n);
		goto out;
	case Qctl:
		break;
	}

	if(n >= sizeof(buf))
		error(Ebadarg);
	strncpy(buf, a, n);
	buf[n] = 0;
	p = strchr(buf, '\n');
	if(p)
		*p = 0;
	p = strchr(buf, ' ');
	if(p)
		*p++ = 0;

	if(strcmp(buf, "fd") == 0){
		s.s->c = buftochan(p);

		/* default is clear (msg delimiters only) */
		s.s->state = Sclear;
		s.s->diglen = 0;
		s.s->max = Maxrecord;
		s.s->in.mid = 0;
		s.s->out.mid = 0;
	} else if(strcmp(buf, "alg") == 0 && p != 0){
		if(s.s->c == 0)
			error("must set fd before algorithm");

		if(strcmp(p, "clear") == 0){
			s.s->state = Sclear;
			s.s->diglen = 0;
			s.s->max = Maxrecord;
			goto out;
		}

		al = lookalg(hashtab, p);
		if(al == nil)
			al = lookalg(encrypttab, p);
		if(al == nil){
			if(strchr(p, ' ') != nil || strchr(p, '/') != nil)
				error("ssl: one algorithm: hmac_sha384 or aes_256_gcm");
			error("ssl: unknown algorithm; hmac_sha384 or aes_256_gcm");
		}

		/*
		 * Each direction its own secret: the same both ways would
		 * give both directions aes_256_gcm's key and nonces, and let
		 * a record sent be returned as one received.
		 */
		if(s.s->in.secret == 0 || s.s->out.secret == 0)
			error("ssl: a secret each way is needed");
		if(s.s->in.slen < Minsecret || s.s->out.slen < Minsecret)
			error("ssl: secret too short; 32 bytes each way at the least");
		if(s.s->in.slen == s.s->out.slen && memcmp(s.s->in.secret, s.s->out.secret, s.s->in.slen) == 0)
			error("ssl: the same secret both ways");

		if(al->state == Saead){
			initGCMkey(&s.s->in);
			initGCMkey(&s.s->out);
		}
		s.s->state = al->state;
		s.s->diglen = al->diglen;
		s.s->max = Maxrecord - s.s->diglen;
	} else if(strcmp(buf, "secretin") == 0 && p != 0) {
		m = (strlen(p)*3)/2;
		x = smalloc(m);
		if(waserror()){
			free(x);
			nexterror();
		}
		t = dec64(x, m, p, strlen(p));
		setsecret(&s.s->in, x, t);
		poperror();
		free(x);
	} else if(strcmp(buf, "secretout") == 0 && p != 0) {
		m = (strlen(p)*3)/2;
		x = smalloc(m);
		if(waserror()){
			free(x);
			nexterror();
		}
		t = dec64(x, m, p, strlen(p));
		setsecret(&s.s->out, x, t);
		poperror();
		free(x);
	} else
		error(Ebadarg);

out:
	qunlock(&s.s->in.ctlq);
	qunlock(&s.s->out.q);
	poperror();
	return n;
}


/* record n's nonce: the direction's, n exclusive-ored into its end */
static void
gcmnonce(OneWay *w)
{
	AESGCMstate *g;
	uvlong n;
	int i;

	g = w->state;
	memmove(g->J0, w->iv, Gcmivlen);
	n = w->mid;
	for(i = 0; i < 8; i++)
		g->J0[Gcmivlen-1-i] ^= n >> (8*i);
	g->J0[12] = 0;
	g->J0[13] = 0;
	g->J0[14] = 0;
	g->J0[15] = 1;
}

/* seal a record: header, then data, which become ciphertext and tag */
static Block*
sealb(Dstate *s, Block *b)
{
	OneWay *w;
	int n;

	w = &s->out;
	n = BLEN(b) - 2;
	b = padblock(b, -Gcmtaglen);
	gcmnonce(w);
	if(aesgcm_encrypt(b->rp + 2, n, b->rp, 2, b->wp, w->state) < 0)
		error("ssl: record too long");
	b->wp += Gcmtaglen;
	return b;
}

/* open a record of len bytes, its ciphertext and tag */
static Block*
openb(Dstate *s, Block *b, int len)
{
	OneWay *w;
	uchar hdr[2];
	int n;

	w = &s->in;
	if(len < Gcmtaglen)
		error("ssl message too short");
	b = pullupblock(b, len);
	if(b == nil)
		error("ssl message too short");
	n = len - Gcmtaglen;
	hdr[0] = 0x80 | (len>>8);
	hdr[1] = len;
	gcmnonce(w);
	if(aesgcm_decrypt(b->rp, n, hdr, 2, b->rp + n, w->state) < 0)
		error("bad digest");
	b->wp = b->rp + n;
	return b;
}

/*
 * The record's MAC, in pieces: macbegin, then macput for each piece,
 * the last with out set to where the digest goes.
 */
static void
macbegin(Dstate *s, OneWay *w, DigestState *ss)
{
	USED(s);
	USED(w);
	memset(ss, 0, sizeof(*ss));
}

static void
macput(Dstate *s, OneWay *w, DigestState *ss, uchar *p, ulong n, uchar *out)
{
	USED(s);
	hmac_sha384(p, n, w->secret, w->slen, out, ss);
}

static Block*
digestb(Dstate *s, Block *b, int offset)
{
	uchar *p;
	DigestState ss;
	uchar msgid[4];
	ulong n, h;
	OneWay *w;

	w = &s->out;

	h = s->diglen + offset;
	n = BLEN(b) - h;

	/* secret + message */
	macbegin(s, w, &ss);
	macput(s, w, &ss, b->rp + h, n, 0);

	/* hash message id */
	p = msgid;
	n = w->mid;
	*p++ = n>>24;
	*p++ = n>>16;
	*p++ = n>>8;
	*p = n;
	macput(s, w, &ss, msgid, 4, b->rp + offset);

	return b;
}

static void
checkdigestb(Dstate *s, Block *inb)
{
	uchar *p;
	DigestState ss;
	uchar msgid[4];
	int n, h;
	OneWay *w;
	uchar digest[128];
	Block *b;

	w = &s->in;

	/* hash secret */
	macbegin(s, w, &ss);

	/* hash message */
	h = s->diglen;
	for(b = inb; b; b = b->next){
		n = BLEN(b) - h;
		if(n < 0)
			panic("checkdigestb");
		macput(s, w, &ss, b->rp + h, n, 0);
		h = 0;
	}

	/* hash message id */
	p = msgid;
	n = w->mid;
	*p++ = n>>24;
	*p++ = n>>16;
	*p++ = n>>8;
	*p = n;
	macput(s, w, &ss, msgid, 4, digest);

	/* requires pullupblock; use constant-time compare to prevent timing oracle */
	{
		int diff;
		const uchar *da;
		const uchar *db;

		if(inb == nil)
			error("missing digest block");
		da = digest;
		db = inb->rp;
		diff = 0;
		for(n = 0; n < s->diglen; n++)
			diff |= da[n] ^ db[n];
		if(diff != 0)
			error("bad digest");
	}
}

/* get channel associated with an fd */
static Chan*
buftochan(char *p)
{
	Chan *c;
	int fd;

	if(p == 0)
		error(Ebadarg);
	fd = strtoul(p, 0, 0);
	if(fd < 0)
		error(Ebadarg);
	c = fdtochan(up->env->fgrp, fd, -1, 0, 1);	/* error check and inc ref */
	return c;
}

/* hang up a digest connection */
static void
sslhangup(Dstate *s)
{
	qlock(&s->in.q);
	freeblist(s->processed);
	s->processed = 0;
	freeblist(s->unprocessed);
	s->unprocessed = 0;
	s->state = Sincomplete;
	qunlock(&s->in.q);
}

static void
dsclone(Chan *ch)
{
	Dstate **pp, **ep, **np;
	int newmax;

	lock(&dslock);
	if(waserror()) {
		unlock(&dslock);
		nexterror();
	}
	ep = &dstate[maxdstate];
	for(pp = dstate; pp < ep; pp++) {
		if(*pp == 0) {
			dsnew(ch, pp);
			break;
		}
	}
	if(pp >= ep) {
		if(maxdstate >= Maxdstate)
			error(Enodev);
		newmax = 2 * maxdstate;
		if(newmax > Maxdstate)
			newmax = Maxdstate;

		np = realloc(dstate, sizeof(Dstate*) * newmax);
		if(np == 0)
			error(Enomem);
		dstate = np;
		pp = &dstate[maxdstate];
		memset(pp, 0, sizeof(Dstate*)*(newmax - maxdstate));

		maxdstate = newmax;
		dsnew(ch, pp);
	}
	poperror();
	unlock(&dslock);
}

static void
dsnew(Chan *ch, Dstate **pp)
{
	Dstate *s;
	int t;

	*pp = s = mallocz(sizeof(*s), 1);
	if(s == nil)
		error(Enomem);
	if(pp - dstate >= dshiwat)
		dshiwat++;
	s->state = Sincomplete;
	s->ref = 1;
	kstrdup(&s->user, up->env->user);
	s->perm = 0660;
	t = TYPE(ch->qid);
	if(t == Qclonus)
		t = Qctl;
	ch->qid.path = QID(pp - dstate, t);
	ch->qid.vers = 0;
	ch->qid.type = QTFILE;
}

Dev ssldevtab = {
	'D',
	"ssl",

	sslinit,
	sslattach,
	sslwalk,
	sslstat,
	sslopen,
	devcreate,
	sslclose,
	sslread,
	sslbread,
	sslwrite,
	sslbwrite,
	devremove,
	sslwstat
};
