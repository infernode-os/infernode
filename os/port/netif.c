/*
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/port/netif.c.
 * The NOTICE at that tree's root states "The bulk of the tree is
 * covered by the permissive MIT licence"; this tree's LICENSE already
 * credits Vita Nuova's revisions.
 *
 * Being ported to 64-bit. No upstream os/ port has ever been LP64, and
 * os/ip is where that matters most quietly: the wire formats are all
 * uchar arrays so sizeof is exact and alignment is 1, but anything
 * holding an ADDRESS or a SEQUENCE NUMBER in a ulong is 32 bits of
 * meaning in a 64-bit word, and the arithmetic on those silently
 * changes answers rather than failing. See tests/host/iproute_test.sh.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/netif.h"

static int netown(Netfile*, char*, int);
static int openfile(Netif*, int);
static char* matchtoken(char*, char*);
static char* netmulti(Netif*, Netfile*, uchar*, int);
static void closefile(Netif*, Netfile*);
static int parseaddr(uchar*, char*, int);

/*
 *  set up a new network interface
 */
void
netifinit(Netif *nif, char *name, int nfile, ulong limit)
{
	strncpy(nif->name, name, KNAMELEN-1);
	nif->name[KNAMELEN-1] = 0;
	nif->nfile = nfile;
	nif->f = malloc(nfile*sizeof(Netfile*));
	if(nif->f)
		memset(nif->f, 0, nfile*sizeof(Netfile*));
	else
		nif->nfile = 0;
	nif->limit = limit;
}

/*
 *  generate a 3 level directory
 */
static int
netifgen(Chan *c, char*, Dirtab *vp, int, int i, Dir *dp)
{
	Qid q;
	Netif *nif = (Netif*)vp;
	Netfile *f;
	int t;
	int perm;
	char *o;

	q.type = QTFILE;
	q.vers = 0;

	/* top level directory contains the name of the network */
	if(c->qid.path == 0){
		switch(i){
		case DEVDOTDOT:
			q.path = 0;
			q.type = QTDIR;
			devdir(c, q, ".", 0, eve, 0555, dp);
			break;
		case 0:
			q.path = N2ndqid;
			q.type = QTDIR;
			strcpy(up->genbuf, nif->name);
			devdir(c, q, up->genbuf, 0, eve, 0555, dp);
			break;
		default:
			return -1;
		}
		return 1;
	}

	/* second level contains clone plus all the conversations */
	t = NETTYPE(c->qid.path);
	/*
	 * stats and ifstats are of this level too. Left out, a stat of
	 * either went on to the third level below as conversation 0's,
	 * and with no conversation 0 was answered "not this one" for
	 * every index: devstat asks until it is told there are no more,
	 * so it asked for ever, on one core, and could not be killed.
	 * /net/ether2 and /net/ether3 are in that state from boot.
	 */
	if(t == N2ndqid || t == Ncloneqid || t == Naddrqid || t == Nstatqid || t == Nifstatqid){
		switch(i) {
		case DEVDOTDOT:
			q.type = QTDIR;
			q.path = 0;
			devdir(c, q, ".", 0, eve, DMDIR|0555, dp);
			break;
		case 0:
			q.path = Ncloneqid;
			devdir(c, q, "clone", 0, eve, 0666, dp);
			break;
		case 1:
			q.path = Naddrqid;
			devdir(c, q, "addr", 0, eve, 0666, dp);
			break;
		case 2:
			q.path = Nstatqid;
			devdir(c, q, "stats", 0, eve, 0444, dp);
			break;
		case 3:
			q.path = Nifstatqid;
			devdir(c, q, "ifstats", 0, eve, 0444, dp);
			break;
		default:
			i -= 4;
			if(i >= nif->nfile)
				return -1;
			if(nif->f[i] == 0)
				return 0;
			q.type = QTDIR;
			q.path = NETQID(i, N3rdqid);
			sprint(up->genbuf, "%d", i);
			devdir(c, q, up->genbuf, 0, eve, DMDIR|0555, dp);
			break;
		}
		return 1;
	}

	/* third level */
	if(NETID(c->qid.path) >= nif->nfile)
		return -1;
	f = nif->f[NETID(c->qid.path)];
	if(f == 0)
		return -1;	/* no such conversation: an end, not "skip this one" */
	if(*f->owner){
		o = f->owner;
		perm = f->mode;
	} else {
		o = eve;
		perm = 0666;
	}
	switch(i){
	case DEVDOTDOT:
		q.type = QTDIR;
		q.path = N2ndqid;
		strcpy(up->genbuf, nif->name);
		devdir(c, q, up->genbuf, 0, eve, DMDIR|0555, dp);
		break;
	case 0:
		q.path = NETQID(NETID(c->qid.path), Ndataqid);
		devdir(c, q, "data", 0, o, perm, dp);
		break;
	case 1:
		q.path = NETQID(NETID(c->qid.path), Nctlqid);
		devdir(c, q, "ctl", 0, o, perm, dp);
		break;
	case 2:
		q.path = NETQID(NETID(c->qid.path), Nstatqid);
		devdir(c, q, "stats", 0, eve, 0444, dp);
		break;
	case 3:
		q.path = NETQID(NETID(c->qid.path), Ntypeqid);
		devdir(c, q, "type", 0, eve, 0444, dp);
		break;
	case 4:
		q.path = NETQID(NETID(c->qid.path), Nifstatqid);
		devdir(c, q, "ifstats", 0, eve, 0444, dp);
		break;
	default:
		return -1;
	}
	return 1;
}

Walkqid*
netifwalk(Netif *nif, Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, (Dirtab *)nif, 0, netifgen);
}

Chan*
netifopen(Netif *nif, Chan *c, int omode)
{
	int id;
	Netfile *f;

	id = 0;
	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Eperm);
	} else {
		switch(NETTYPE(c->qid.path)){
		case Ndataqid:
		case Nctlqid:
			id = NETID(c->qid.path);
			openfile(nif, id);
			break;
		case Ncloneqid:
			id = openfile(nif, -1);
			c->qid.path = NETQID(id, Nctlqid);
			break;
		default:
			if(omode != OREAD)
				error(Ebadarg);
		}
		switch(NETTYPE(c->qid.path)){
		case Ndataqid:
		case Nctlqid:
			f = nif->f[id];
			if(netown(f, up->env->user, omode&7) < 0){
				/*
				 * openfile counted this open: left counted,
				 * a refused open (of clone for execute, say)
				 * kept its conversation for good, and there
				 * are only so many
				 */
				closefile(nif, f);
				error(Eperm);
			}
			break;
		}
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	c->iounit = qiomaxatomic;
	return c;
}

long
netifread(Netif *nif, Chan *c, void *a, long n, ulong offset)
{
	int i, j;
	Netfile *f;
	char *p;

	if(c->qid.type&QTDIR)
		return devdirread(c, a, n, (Dirtab*)nif, 0, netifgen);

	switch(NETTYPE(c->qid.path)){
	case Ndataqid:
		f = nif->f[NETID(c->qid.path)];
		return qread(f->in, a, n);
	case Nctlqid:
		return readnum(offset, a, n, NETID(c->qid.path), NUMSIZE);
	case Nstatqid:
		p = malloc(READSTR);
		if(p == nil)
			return 0;
		if(waserror()){
			free(p);
			nexterror();
		}
		j = snprint(p, READSTR, "in: %d\n", nif->inpackets);
		j += snprint(p+j, READSTR-j, "link: %d\n", nif->link);
		j += snprint(p+j, READSTR-j, "out: %d\n", nif->outpackets);
		j += snprint(p+j, READSTR-j, "crc errs: %d\n", nif->crcs);
		j += snprint(p+j, READSTR-j, "overflows: %d\n", nif->overflows);
		j += snprint(p+j, READSTR-j, "soft overflows: %d\n", nif->soverflows);
		j += snprint(p+j, READSTR-j, "framing errs: %d\n", nif->frames);
		j += snprint(p+j, READSTR-j, "buffer errs: %d\n", nif->buffs);
		j += snprint(p+j, READSTR-j, "output errs: %d\n", nif->oerrs);
		j += snprint(p+j, READSTR-j, "prom: %d\n", nif->prom);
		j += snprint(p+j, READSTR-j, "mbps: %d\n", nif->mbps);
		j += snprint(p+j, READSTR-j, "addr: ");
		for(i = 0; i < nif->alen; i++)
			j += snprint(p+j, READSTR-j, "%2.2ux", nif->addr[i]);
		snprint(p+j, READSTR-j, "\n");
		n = readstr(offset, a, n, p);
		free(p);
		poperror();
		return n;
	case Naddrqid:
		p = malloc(READSTR);
		if(p == nil)
			return 0;
		if(waserror()){
			free(p);
			nexterror();
		}
		j = 0;
		for(i = 0; i < nif->alen; i++)
			j += snprint(p+j, READSTR-j, "%2.2ux", nif->addr[i]);
		n = readstr(offset, a, n, p);
		free(p);
		poperror();
		return n;
	case Ntypeqid:
		f = nif->f[NETID(c->qid.path)];
		return readnum(offset, a, n, f->type, NUMSIZE);
	case Nifstatqid:
		return 0;
	}
	error(Ebadarg);
	return -1;	/* not reached */
}

Block*
netifbread(Netif *nif, Chan *c, long n, ulong offset)
{
	if((c->qid.type & QTDIR) || NETTYPE(c->qid.path) != Ndataqid)
		return devbread(c, n, offset);

	return qbread(nif->f[NETID(c->qid.path)]->in, n);
}

/*
 *  make sure this type isn't already in use on this device
 */
static int
typeinuse(Netif *nif, int type)
{
	Netfile *f, **fp, **efp;

	if(type <= 0)
		return 0;

	efp = &nif->f[nif->nfile];
	for(fp = nif->f; fp < efp; fp++){
		f = *fp;
		if(f == 0)
			continue;
		if(f->type == type)
			return 1;
	}
	return 0;
}

/*
 *  the devxxx.c that calls us handles writing data, it knows best
 */
long
netifwrite(Netif *nif, Chan *c, void *a, long n)
{
	Netfile *f;
	int type;
	char *p, buf[64];
	uchar binaddr[Nmaxaddr];

	if(NETTYPE(c->qid.path) != Nctlqid)
		error(Eperm);

	if(n >= sizeof(buf))
		n = sizeof(buf)-1;
	memmove(buf, a, n);
	buf[n] = 0;

	if(waserror()){
		qunlock(&nif->ql);
		nexterror();
	}

	qlock(&nif->ql);
	f = nif->f[NETID(c->qid.path)];
	if((p = matchtoken(buf, "connect")) != 0){
		type = atoi(p);
		if(typeinuse(nif, type))
			error(Einuse);
		f->type = type;
		if(f->type < 0)
			nif->all++;
	} else if(matchtoken(buf, "promiscuous")){
		if(f->prom == 0){
			if(nif->prom == 0 && nif->promiscuous != nil)
				nif->promiscuous(nif->arg, 1);
			f->prom = 1;
			nif->prom++;
		}
	} else if((p = matchtoken(buf, "scanbs")) != 0){
		/* scan for base stations */
		if(f->scan == 0){
			type = atoi(p);
			if(type < 5)
				type = 5;
			if(nif->scanbs != nil)
				nif->scanbs(nif->arg, type);
			f->scan = type;
			nif->scan++;
		}
	} else if(matchtoken(buf, "bridge")){
		f->bridge = 1;
	} else if(matchtoken(buf, "headersonly")){
		f->headersonly = 1;
	} else if((p = matchtoken(buf, "addmulti")) != 0){
		if(parseaddr(binaddr, p, nif->alen) < 0)
			error("bad address");
		p = netmulti(nif, f, binaddr, 1);
		if(p)
			error(p);
	} else if((p = matchtoken(buf, "remmulti")) != 0){
		if(parseaddr(binaddr, p, nif->alen) < 0)
			error("bad address");
		p = netmulti(nif, f, binaddr, 0);
		if(p)
			error(p);
	} else
		n = -1;
	qunlock(&nif->ql);
	poperror();
	return n;
}

int
netifwstat(Netif *nif, Chan *c, uchar *db, int n)
{
	Dir *dir;
	Netfile *f;
	int m;

	f = nif->f[NETID(c->qid.path)];
	if(f == 0)
		error(Enonexist);

	if(netown(f, up->env->user, OWRITE) < 0)
		error(Eperm);

	dir = smalloc(sizeof(Dir)+n);
	if(waserror()){
		free(dir);
		nexterror();
	}
	m = convM2D(db, n, &dir[0], (char*)&dir[1]);
	if(m == 0)
		error(Eshortstat);
	if(!emptystr(dir[0].uid)){
		strncpy(f->owner, dir[0].uid, KNAMELEN-1);
		f->owner[KNAMELEN-1] = 0;
	}
	if(dir[0].mode != ~0UL)
		f->mode = dir[0].mode;
	free(dir);
	poperror();
	return m;
}

int
netifstat(Netif *nif, Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, (Dirtab *)nif, 0, netifgen);
}

/*
 * One open of a conversation gone; with the last, what the conversation
 * asked of the interface is given back. The interface's lock is taken
 * before the conversation's, as openfile takes them for a clone: this
 * took them the other way about, and the two could wait for each other.
 */
static void
closefile(Netif *nif, Netfile *f)
{
	int t;
	Netaddr *ap;

	qlock(&nif->ql);
	qlock(&f->ql);
	if(--(f->inuse) == 0){
		if(f->prom){
			if(--(nif->prom) == 0 && nif->promiscuous != nil)
				nif->promiscuous(nif->arg, 0);
			f->prom = 0;
		}
		if(f->scan){
			if(--(nif->scan) == 0 && nif->scanbs != nil)
				nif->scanbs(nif->arg, 0);
			f->prom = 0;
			f->scan = 0;
		}
		if(f->nmaddr){
			/*
			 * each join this conversation made, by the address's
			 * place in the list (t was never advanced: every address
			 * was released if the first was the conversation's,
			 * and none otherwise)
			 */
			t = 0;
			for(ap = nif->maddr; ap != nil && t < nelem(f->maddr); ap = ap->next, t++){
				while(f->maddr[t] != 0)
					netmulti(nif, f, ap->addr, 0);
			}
			f->nmaddr = 0;
			memset(f->maddr, 0, sizeof(f->maddr));
		}
		if(f->type < 0)
			--(nif->all);
		f->owner[0] = 0;
		f->type = 0;
		f->bridge = 0;
		f->headersonly = 0;
		qclose(f->in);
	}
	qunlock(&f->ql);
	qunlock(&nif->ql);
}

void
netifclose(Netif *nif, Chan *c)
{
	int t;

	if((c->flag & COPEN) == 0)
		return;

	t = NETTYPE(c->qid.path);
	if(t != Ndataqid && t != Nctlqid)
		return;

	closefile(nif, nif->f[NETID(c->qid.path)]);
}

Lock netlock;

static int
netown(Netfile *p, char *o, int omode)
{
	static int access[] = { 0400, 0200, 0600, 0100 };
	int mode;
	int t;

	lock(&netlock);
	if(*p->owner){
		if(strncmp(o, p->owner, KNAMELEN) == 0)	/* User */
			mode = p->mode;
		else if(strncmp(o, eve, KNAMELEN) == 0)	/* Bootes is group */
			mode = p->mode<<3;
		else
			mode = p->mode<<6;		/* Other */

		t = access[omode&3];
		if((t & mode) == t){
			unlock(&netlock);
			return 0;
		} else {
			unlock(&netlock);
			return -1;
		}
	}
	strncpy(p->owner, o, KNAMELEN-1);
	p->owner[KNAMELEN-1] = 0;
	p->mode = 0660;
	unlock(&netlock);
	return 0;
}

/*
 *  Increment the reference count of a network device.
 *  If id < 0, return an unused ether device.
 */
static int
openfile(Netif *nif, int id)
{
	Netfile *f, **fp, **efp;

	if(id >= 0){
		f = nif->f[id];
		if(f == 0)
			error(Enodev);
		qlock(&f->ql);
		qreopen(f->in);
		f->inuse++;
		qunlock(&f->ql);
		return id;
	}

	qlock(&nif->ql);
	if(waserror()){
		qunlock(&nif->ql);
		nexterror();
	}
	efp = &nif->f[nif->nfile];
	for(fp = nif->f; fp < efp; fp++){
		f = *fp;
		if(f == 0){
			f = malloc(sizeof(Netfile));
			if(f == 0)
				exhausted("memory");
			f->in = qopen(nif->limit, Qmsg, 0, 0);
			if(f->in == nil){
				free(f);
				exhausted("memory");
			}
			*fp = f;
			qlock(&f->ql);
		} else {
			qlock(&f->ql);
			if(f->inuse){
				qunlock(&f->ql);
				continue;
			}
		}
		f->inuse = 1;
		qreopen(f->in);
		netown(f, up->env->user, 0);
		qunlock(&f->ql);
		qunlock(&nif->ql);
		poperror();
		return fp - nif->f;
	}
	error(Enodev);
	return -1;	/* not reached */
}

/*
 *  look for a token starting a string,
 *  return a pointer to first non-space char after it
 */
static char*
matchtoken(char *p, char *token)
{
	int n;

	n = strlen(token);
	if(strncmp(p, token, n))
		return 0;
	p += n;
	if(*p == 0)
		return p;
	if(*p != ' ' && *p != '\t' && *p != '\n')
		return 0;
	while(*p == ' ' || *p == '\t' || *p == '\n')
		p++;
	return p;
}

static ulong
hash(uchar *a, int len)
{
	ulong sum = 0;

	while(len-- > 0)
		sum = (sum << 1) + *a++;
	return sum%Nmhash;
}

int
activemulti(Netif *nif, uchar *addr, int alen)
{
	Netaddr *hp;

	for(hp = nif->mhash[hash(addr, alen)]; hp; hp = hp->hnext)
		if(memcmp(addr, hp->addr, alen) == 0){
			if(hp->ref)
				return 1;
			else
				break;
		}
	return 0;
}

static int
parseaddr(uchar *to, char *from, int alen)
{
	char nip[4];
	char *p;
	int i;

	p = from;
	for(i = 0; i < alen; i++){
		if(*p == 0)
			return -1;
		nip[0] = *p++;
		if(*p == 0)
			return -1;
		nip[1] = *p++;
		nip[2] = 0;
		to[i] = strtoul(nip, 0, 16);
		if(*p == ':')
			p++;
	}
	return 0;
}

/*
 *  keep track of multicast addresses
 */
static char*
netmulti(Netif *nif, Netfile *f, uchar *addr, int add)
{
	Netaddr **l, *ap, *dead, **hl;
	int i, di;
	ulong h;

	if(nif->multicast == nil)
		return "interface does not support multicast";

	/*
	 * An address's place in the list is its place in each conversation's
	 * counts, so an entry is never taken out; one nobody has joined (ref
	 * 0) is used again for the next new address. The list is therefore
	 * no longer than a conversation has counts. It grew by one for
	 * every new address ever added, and a driver that programs a
	 * filter from it (ethergenet's) was led past its table.
	 *
	 * A conversation's joins of an address are counted, and each leave
	 * gives one back. IP joins a group once for each local address that
	 * needs it, all through one conversation (addselfcache), and leaves
	 * once for each: a link-local and a global address with the same
	 * last three bytes share a solicited-node group. With a join taken
	 * once however often it was asked for, removing either address left
	 * the group for both, and neighbour discovery for the one that
	 * remained went unanswered.
	 */
	l = &nif->maddr;
	i = 0;
	dead = nil;
	di = -1;
	for(ap = *l; ap; ap = *l){
		if(ap->ref > 0 && memcmp(addr, ap->addr, nif->alen) == 0)
			break;
		if(ap->ref <= 0 && dead == nil){
			dead = ap;
			di = i;
		}
		i++;
		l = &ap->next;
	}

	if(add){
		if(ap != 0 && f->maddr[i] == (ushort)~0)
			return "too many joins of a multicast address";
		if(ap == 0){
			if(dead != nil){
				/* an entry nobody has: out of its hash chain, and given the new address */
				h = hash(dead->addr, nif->alen);
				for(hl = &nif->mhash[h]; *hl != nil; hl = &(*hl)->hnext)
					if(*hl == dead){
						*hl = dead->hnext;
						break;
					}
				ap = dead;
				i = di;
			}else{
				if(i >= nelem(f->maddr))
					return "too many multicast addresses";
				*l = ap = smalloc(sizeof(*ap));
				ap->next = 0;
			}
			memmove(ap->addr, addr, nif->alen);
			ap->ref = 1;
			h = hash(addr, nif->alen);
			ap->hnext = nif->mhash[h];
			nif->mhash[h] = ap;
		} else {
			ap->ref++;
		}
		if(ap->ref == 1){
			nif->nmaddr++;
			nif->multicast(nif->arg, addr, 1);
		}
		if(f->maddr[i]++ == 0)
			f->nmaddr++;
	} else {
		/*
		 * only a join this conversation made: any other's was
		 * given back by whoever asked, and its owner's count
		 * left over a reference that had gone
		 */
		if(ap == 0 || i >= nelem(f->maddr) || f->maddr[i] == 0)
			return 0;
		ap->ref--;
		if(ap->ref == 0){
			nif->nmaddr--;
			nif->multicast(nif->arg, addr, 0);
		}
		if(--f->maddr[i] == 0)
			f->nmaddr--;
	}
	return 0;
}
