/*
 * #s -- the server device, and Sys->file2chan.
 *
 * IMPORTED from emu/port/devsrv.c. It is the same device: a name in #s
 * is a channel a Limbo program serves, so that a program can BE a file
 * server without any of it living in the kernel. Only the include
 * preamble differs -- emu's sources start at dat.h and pull in their
 * own lib9.h, while a native kernel leads with u.h and takes lib.h and
 * error.h from os/port -- which is exactly the change devpipe.c needed.
 *
 * It is not optional for a window system. wmsrv, which is how every
 * client reaches the window manager, is a Limbo file server built on
 * sys->file2chan, and file2chan is srvf2c in here. Without it,
 * "wm/wm" got as far as trying to serve its namespace and stopped:
 *
 *     [Sh] Broken: "devsrv not imported: file2chan unavailable"
 *
 * The same seam is how a Limbo program serves anything else it wants
 * other programs to reach by name, so this is a good deal more general
 * than the window manager that motivated it.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"interp.h"
#include	<isa.h>
#include	"runt.h"

typedef struct SrvFile SrvFile;
typedef struct Pending Pending;
typedef struct Notes Notes;
typedef union Note Note;

/* request pending to a server, in case a server vanishes */
struct Pending
{
	Pending*	next;
	Pending*	prev;
	int fid;
	Channel*	rc;
	Channel*	wc;
};

/* what a server is sent when a file is closed: a request with no reply channel */
union Note
{
	Sys_FileIO_read	r;
	Sys_FileIO_write	w;
};

/*
 * The closes a server has yet to be told of, on one of its channels:
 * see noteclose.
 */
struct Notes
{
	Channel*	c;		/* the server's channel (SrvFile.read or .write, while that is not H) */
	int	iswrite;
	Prog	p;		/* stands in c's queue of senders with one of them */
	int	queued;		/* p is there, with msg */
	Note	msg;
	int*	fid;		/* the others, each fid once */
	int	nfid;
	int	mfid;		/* room: at least nfid and the file's opens (noteroom) */
};

struct SrvFile
{
	char*	name;
	char*	user;
	ulong		perm;
	Qid		qid;
	int		ref;

	/* root directory */
	char*	spec;
	SrvFile*	devlist;
	SrvFile*	entry;

	/* file */
	int		opens;
	int		flags;
	vlong	length;
	Channel*	read;
	Channel*	write;
	SrvFile*	dir;		/* parent directory */
	Pending	waitlist;	/* pending requests from client opens */
	Vm*	vm;		/* the VM of the program serving it, whose channels these are (#944) */
	Notes	rnote;		/* closes not yet sent on read */
	Notes	wnote;		/* and on write */
};

enum
{
	SORCLOSE	= (1<<0),
	SRDCLOSE	= (1<<1),
	SWRCLOSE	= (1<<2),
	SREMOVED	= (1<<3),
};

typedef struct SrvDev SrvDev;
struct SrvDev
{
	Type*	Rread;
	Type*	Rwrite;
	QLock	l;
	ulong	pathgen;
	SrvFile*	devices;
};

static SrvDev dev;

void	freechan(Heap*, int);
static void	freerdchan(Heap*, int);
static void	freewrchan(Heap*, int);
static void delwaiting(Pending*);
static void	noteroom(SrvFile*);
static void	notestop(Notes*);

Type	*Trdchan;
Type	*Twrchan;

static int
srvgen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	SrvFile *f;

	USED(name);
	USED(tab);
	USED(ntab);

	if(s == DEVDOTDOT){
		devdir(c, c->qid, "#s", 0, eve, 0555, dp);
		return 1;
	}
	f = c->aux;
	if((c->qid.type & QTDIR) == 0){
		if(s > 0)
			return -1;
		devdir(c, f->qid, f->name, f->length, f->user, f->perm, dp);
		return 1;
	}

	for(f = f->entry; f != nil; f = f->entry){
		if(s-- == 0)
			break;
	}
	if(f == nil)
		return -1;

	devdir(c, f->qid, f->name, f->length, f->user, f->perm, dp);
	return 1;
}

static void
srvinit(void)
{
	static uchar rmap[] = Sys_Rread_map;
	static uchar wmap[] = Sys_Rwrite_map;

	Trdchan = dtype(freerdchan, sizeof(Channel), Tchannel.map, Tchannel.np);
	Twrchan = dtype(freewrchan, sizeof(Channel), Tchannel.map, Tchannel.np);

	dev.pathgen = 1;
	dev.Rread = dtype(freeheap, Sys_Rread_size, rmap, sizeof(rmap));
	dev.Rwrite = dtype(freeheap, Sys_Rwrite_size, wmap, sizeof(wmap));
}

static int
srvcanattach(SrvFile *d)
{
	if(strcmp(d->user, up->env->user) == 0)
		return 1;

	/*
	 * Need write permission in other to allow attaches if
	 * we are not the owner
	 */
	if(d->perm & 2)
		return 1;

	return 0;
}

static Chan*
srvattach(char *spec)
{
	Chan *c;
	SrvFile *d;
	char srvname[16];

	qlock(&dev.l);
	if(waserror()){
		qunlock(&dev.l);
		nexterror();
	}

	if(spec[0] != '\0'){
		for(d = dev.devices; d != nil; d = d->devlist){
			if(strcmp(spec, d->spec) == 0){
				if(!srvcanattach(d))
					error(Eperm);
				c = devattach('s', spec);
				c->aux = d;
				c->qid = d->qid;
				d->ref++;
				poperror();
				qunlock(&dev.l);
				return c;
			}
		}
	}

	d = malloc(sizeof(SrvFile));
	if(d == nil)
		error(Enomem);

	d->ref = 1;
	kstrdup(&d->spec, spec);
	kstrdup(&d->user, up->env->user);
	snprint(srvname, sizeof(srvname), "srv%ld", up->env->pgrp->pgrpid);
	kstrdup(&d->name, srvname);
	d->perm = DMDIR|0770;
	mkqid(&d->qid, dev.pathgen++, 0, QTDIR);

	d->devlist = dev.devices;
	dev.devices = d;

	poperror();
	qunlock(&dev.l);

	c = devattach('s', spec);
	c->aux = d;
	c->qid = d->qid;

	return c;
}

static Walkqid*
srvwalk(Chan *c, Chan *nc, char **name, int nname)
{
	SrvFile *d, *pd;
	Walkqid *w;

	pd = c->aux;
	qlock(&dev.l);
	if(waserror()){
		qunlock(&dev.l);
		nexterror();
	}

	w = devwalk(c, nc, name, nname, nil, 0, srvgen);
	if(w != nil && w->clone != nil){
		if(nname != 0 && w->clone->qid.path != pd->qid.path){
			for(d = pd->entry; d != nil; d = d->entry)
				if(d->qid.path == w->clone->qid.path)
					break;
			if(d == nil){
				/* not to be: srvgen made the qid from this list, under this lock */
				if(w->clone != c){
					w->clone->aux = pd;
					pd->ref++;
					cclose(w->clone);
				}
				free(w);
				error(Enonexist);
			}
			if(w->clone == c)
				pd->ref--;
		}else{
			/*
			 * the directory itself: no names, or a walk to "..",
			 * which srvgen answers with the directory. That was
			 * looked for among the directory's files, not found,
			 * and a panic: stat("#s/..") from any program, #s
			 * being a device it keeps after NODEVS.
			 */
			d = pd;
			if(nname != 0 && w->clone == c)
				pd->ref--;
		}
		w->clone->aux = d;
		d->ref++;
	}

	poperror();
	qunlock(&dev.l);
	return w;
}

static int
srvstat(Chan *c, uchar *db, int n)
{
	qlock(&dev.l);
	if(waserror()){
		qunlock(&dev.l);
		nexterror();
	}
	n = devstat(c, db, n, 0, 0, srvgen);
	poperror();
	qunlock(&dev.l);
	return n;
}

static Chan*
srvopen(Chan *c, int omode)
{
	SrvFile *sf;

	openmode(omode);	/* check it */
	if(c->qid.type & QTDIR){
		if(omode != OREAD)
			error(Eisdir);
		c->mode = omode;
		c->flag |= COPEN;
		c->offset = 0;
		return c;
	}

	sf = c->aux;

	qlock(&dev.l);
	if(waserror()){
		qunlock(&dev.l);
		nexterror();
	}
	devpermcheck(sf->user, sf->perm, omode);
	if(omode&ORCLOSE && strcmp(sf->user, up->env->user) != 0)
		error(Eperm);
	if(sf->perm & DMEXCL && sf->opens != 0)
		error(Einuse);
	noteroom(sf);		/* for this open's close */
	sf->opens++;
	if(omode&ORCLOSE)
		sf->flags |= SORCLOSE;
	poperror();
	qunlock(&dev.l);

	c->offset = 0;
	c->flag |= COPEN;
	c->mode = openmode(omode);

	return c;
}

static int
srvwstat(Chan *c, uchar *dp, int n)
{
	Dir *d;
	SrvFile *sf, *f;

	sf = c->aux;
	if(strcmp(up->env->user, sf->user) != 0)
		error(Eperm);

	d = smalloc(sizeof(*d)+n);
	if(waserror()){
		free(d);
		nexterror();
	}
	n = convM2D(dp, n, d, (char*)&d[1]);
	if(n == 0)
		error(Eshortstat);
	if(!emptystr(d->name)){
		if(sf->dir == nil)
			error(Eperm);
		validwstatname(d->name);
		qlock(&dev.l);
		for(f = sf->dir; f != nil; f = f->entry)
			if(strcmp(f->name, d->name) == 0){
				qunlock(&dev.l);
				error(Eexist);
			}
		kstrdup(&sf->name, d->name);
		qunlock(&dev.l);
	}
	if(d->mode != ~0UL)
		sf->perm = d->mode & (DMEXCL|DMAPPEND|0777);
	if(d->length != (vlong)-1)
		sf->length = d->length;
	poperror();
	free(d);
	return n;
}

static void
srvputdir(SrvFile *dir)
{
	SrvFile **l, *d;

	dir->ref--;
	if(dir->ref != 0)
		return;

	for(l = &dev.devices; (d = *l) != nil; l = &d->devlist)
		if(d == dir){
			*l = d->devlist;
			break;
		}
	free(dir->spec);
	free(dir->user);
	free(dir->name);
	free(dir);
}

/*
 * A served file's channels belong to the VM of the program that made it
 * (#944). A client in another VM -- or the kernel closing the file for
 * one -- must do its channel work under THAT VM's interpreter, and
 * allocate the request and reply there: the server's VM is the one that
 * will read them. So the process takes the server's VM for the length
 * of the request, and gives back its own at the end, on every path.
 */
static Vm*
srvacquire(SrvFile *sf)
{
	Vm *home;

	home = up->vm;
	if(sf->vm != nil)
		up->vm = sf->vm;
	acquire();
	return home;
}

static void
srvrelease(Vm *home)
{
	release();
	up->vm = home;
}

/*
 * A server is given the offset as a Limbo int.  An offset past the
 * largest was cut to its low 32 bits: from 2^31 a negative number, which
 * a server slicing its data by it took as an array bounds error and
 * died of, from any client that can read or write the file; from 2^32 a
 * small one again.  The largest int stands for all of them.
 */
static int
srvoffset(vlong offset)
{
	if(offset < 0)
		return 0;
	if(offset > 0x7fffffffLL)
		return 0x7fffffff;
	return offset;
}

/*
 * A close is told to the server on both its channels: a request with
 * no reply channel.  It was sent only if the channel's buffer (sixteen)
 * had room at that moment, and dropped with a message on the console
 * if not: a server busy for a moment while seventeen files were closed
 * never heard of the seventeenth, and one that counts its clients kept
 * that one for good, so opening and closing quickly used up a service's
 * limit.  The closer cannot wait for room: the server may never take
 * anything from that channel (the plumber never reads its read
 * channel), and a close is made by exiting processes and by the
 * collector.
 *
 * So the notices that do not fit wait in Notes, as fids, and one of
 * them at a time waits in the channel's own queue of senders, behind
 * the buffer and whoever was there first, held by a Prog that is no
 * process: when the server's receive takes it, addrun calls noted
 * (as it calls cwakeme for a process blocked in csend), which puts
 * the next one there.  Nothing waits and nothing is made at a close:
 * the room for an open's close is taken when it is opened.
 *
 * A fid is the Chan's, and the next open to be given that Chan has the
 * same fid.  A server must hear of the close before it hears from the
 * new open, so a read or write first sends, itself, a notice of its own
 * fid still waiting on that channel (noteflush).  That is also why a
 * fid waits only once on a channel: between two closes of it with
 * nothing sent on the channel for it, the server has nothing of the
 * fid's to forget twice.  So what waits is bounded by the fids there
 * are, which is the Chans the kernel has made, four bytes each.
 *
 * All of it is done with the interpreter held (acquire), as the
 * channel's own queues are.
 */
static void
mknote(Notes *n, Note *m, int fid)
{
	if(n->iswrite){
		m->w.t0 = 0;
		m->w.t1 = H;
		m->w.t2 = fid;
		m->w.t3 = H;
	}else{
		m->r.t0 = 0;
		m->r.t1 = 0;
		m->r.t2 = fid;
		m->r.t3 = H;
	}
}

static int
notefind(Notes *n, int fid)
{
	int i;

	for(i = 0; i < n->nfid; i++)
		if(n->fid[i] == fid)
			return i;
	return -1;
}

static void
notedel(Notes *n, int i)
{
	n->nfid--;
	memmove(n->fid+i, n->fid+i+1, (n->nfid-i)*sizeof(int));
}

/* will a send on d go at once? */
static int
canput(Channel *d)
{
	return d->recv->prog != nil || (d->buf != H && d->size < d->buf->len);
}

static void	noted(Prog*);

/*
 * Leave the first of what waits in the channel's queue of senders.
 */
static void
notequeue(Notes *n)
{
	if(n->queued || n->nfid == 0)
		return;
	mknote(n, &n->msg, n->fid[0]);
	n->p.state = Psend;
	n->p.kill = nil;
	n->p.osenv = n;
	n->p.addrun = noted;
	n->p.ptr = &n->msg;
	if(!cqaddok(&n->c->send, &n->p)){
		/* no memory for a place in the queue: it stays with the others, for the next close, read or write to send on */
		n->p.ptr = nil;
		return;
	}
	notedel(n, 0);
	n->queued = 1;
}

/*
 * Send what waits while it goes at once, in the order it came, and
 * queue the next.
 */
static void
notego(Notes *n)
{
	Channel *d;
	Note m;

	d = n->c;
	if(n->queued)
		return;
	while(n->nfid > 0 && canput(d)){
		mknote(n, &m, n->fid[0]);
		notedel(n, 0);
		csendalt(d, &m, d->mid.t, -1);
	}
	notequeue(n);
}

/*
 * addrun, for Notes.p: the server has received, and the notice p held
 * went into the buffer in the place that made; or the channel is being
 * freed (killcomm), which notestop should have come before.  This is
 * inside the server's receive: the buffer is full again, and the
 * server, in an alt, is itself still in the queue of receivers, where
 * it must not be taken for one that waits.  So the next is queued, not
 * sent.
 */
static void
noted(Prog *p)
{
	Notes *n;

	n = p->osenv;
	n->queued = 0;
	if(p->kill != nil){
		p->kill = nil;
		n->nfid = 0;
		return;
	}
	notequeue(n);
}

/* the channel is going: nothing more is sent on it */
static void
notestop(Notes *n)
{
	if(n->queued){
		cqdelp(&n->c->send, &n->p);
		n->p.ptr = nil;
		n->queued = 0;
	}
	n->nfid = 0;
}

static void
noteclose(Notes *n, int fid, int opens)
{
	if(notefind(n, fid) < 0){
		if(n->nfid >= n->mfid){
			/* not to be: noteroom took the room when it was opened */
			print("devsrv: no room to tell a server of a close\n");
			return;
		}
		n->fid[n->nfid++] = fid;
	}
	notego(n);
	if(opens == 0 && n->nfid == 0 && n->mfid > 64){
		/* a crowd has been and gone */
		free(n->fid);
		n->fid = nil;
		n->mfid = 0;
	}
}

/*
 * Room for the notices of every open's close, taken as the file is
 * opened (dev.l held), where having none can be refused.
 */
static void
noteroom1(Notes *n, int opens)
{
	int m, *f;

	m = n->nfid + opens + 1;
	if(m <= n->mfid)
		return;
	m += 16;
	f = malloc(m*sizeof(int));
	if(f == nil)
		error(Enomem);
	if(n->nfid > 0)
		memmove(f, n->fid, n->nfid*sizeof(int));
	free(n->fid);
	n->fid = f;
	n->mfid = m;
}

static void
noteroom(SrvFile *sf)
{
	Vm *home;

	home = srvacquire(sf);
	if(waserror()){
		srvrelease(home);
		nexterror();
	}
	noteroom1(&sf->rnote, sf->opens);
	noteroom1(&sf->wnote, sf->opens);
	poperror();
	srvrelease(home);
}

/*
 * Before a request for fid is sent on n's channel: a close of the
 * fid's last open that still waits goes first, sent by the requester,
 * which can wait.  Interrupted, it is put back: it may have been sent
 * as the interrupt came, and a server told twice that a fid has gone
 * forgets nothing it should keep.
 */
static void
noteflush(SrvFile *sf, Notes *n, int fid)
{
	int i;
	Note m;

	i = notefind(n, fid);
	if(i < 0 || (n->iswrite? sf->write: sf->read) == H)
		return;
	notedel(n, i);
	mknote(n, &m, fid);
	if(waserror()){
		if((n->iswrite? sf->write: sf->read) != H && notefind(n, fid) < 0 && n->nfid < n->mfid){
			n->fid[n->nfid++] = fid;
			notego(n);
		}
		nexterror();
	}
	csend(n->c, &m);
	poperror();
}

static void
srvunblock(SrvFile *sf, int fid)
{
	Vm *home;

	home = srvacquire(sf);
	if(waserror()){
		srvrelease(home);
		nexterror();
	}
	if(sf->read != H)
		noteclose(&sf->rnote, fid, sf->opens);
	if(sf->write != H)
		noteclose(&sf->wnote, fid, sf->opens);
	poperror();
	srvrelease(home);
}

static void
srvcancelreqs(SrvFile *sf)
{
	Vm *home;
	Pending *w, *ws;
	Sys_Rread rreply;
	Sys_Rwrite wreply;

	home = srvacquire(sf);
	ws = &sf->waitlist;
	while((w = ws->next) != ws){
		delwaiting(w);
		if(waserror() == 0){
			if(w->rc != nil){
				rreply.t0 = H;
				rreply.t1 = c2string(Ehungup, strlen(Ehungup));
				csend(w->rc, &rreply);
				destroy(rreply.t1);	/* the channel has its own */
			}
			if(w->wc != nil){
				wreply.t0 = 0;
				wreply.t1 = c2string(Ehungup, strlen(Ehungup));
				csend(w->wc, &wreply);
				destroy(wreply.t1);
			}
			poperror();
		}
	}
	srvrelease(home);
}

static void
srvdelete(SrvFile *sf)
{
	SrvFile *f, **l;

	if((sf->flags & SREMOVED) == 0){
		for(l = &sf->dir->entry; (f = *l) != nil; l = &f->entry){
			if(sf == f){
				*l = f->entry;
				break;
			}
		}
		sf->ref--;
		sf->flags |= SREMOVED;
	}
}

static void
srvchkref(SrvFile *sf)
{
	if(sf->ref != 0)
		return;

	if(sf->dir != nil)
		srvputdir(sf->dir);

	free(sf->rnote.fid);
	free(sf->wnote.fid);
	free(sf->user);
	free(sf->name);
	free(sf);
}

static void
srvfree(SrvFile *sf, int flag)
{
	sf->flags |= flag;
	if((sf->flags & (SRDCLOSE | SWRCLOSE)) == (SRDCLOSE | SWRCLOSE)){
		sf->ref--;
		srvdelete(sf);
		/* no further requests can arrive; return error to pending requests */
		srvcancelreqs(sf);
		srvchkref(sf);
	}
}

static void
freerdchan(Heap *h, int swept)
{
	SrvFile *sf;
	Dsave ds;

	sf = H2D(Channel*, h)->aux;
	notestop(&sf->rnote);	/* before killcomm finds its Prog, and while sf is certainly there */
	destroysave(&ds);	/* release() inside a destroy: heap.c */
	release();
	qlock(&dev.l);
	sf->read = H;
	srvfree(sf, SRDCLOSE);
	qunlock(&dev.l);
	acquire();
	destroyrestore(&ds);

	freechan(h, swept);
}

static void
freewrchan(Heap *h, int swept)
{
	SrvFile *sf;
	Dsave ds;

	sf = H2D(Channel*, h)->aux;
	notestop(&sf->wnote);
	destroysave(&ds);	/* release() inside a destroy: heap.c */
	release();
	qlock(&dev.l);
	sf->write = H;
	srvfree(sf, SWRCLOSE);
	qunlock(&dev.l);
	acquire();
	destroyrestore(&ds);

	freechan(h, swept);
}

static void
srvclunk(Chan *c, int remove)
{
	int opens, noperm;
	SrvFile *sf;

	sf = c->aux;
	qlock(&dev.l);
	if(c->qid.type & QTDIR){
		srvputdir(sf);
		qunlock(&dev.l);
		if(remove)
			error(Eperm);
		return;
	}
	opens = 0;
	if(c->flag & COPEN){
		opens = sf->opens--;
		if(sf->read != H || sf->write != H){
			/*
			 * a clunk finishes whatever becomes of telling the
			 * server: an error here left dev.l held, for good
			 */
			if(!waserror()){
				srvunblock(sf, c->fid);
				poperror();
			}
		}
	}

	sf->ref--;
	if(opens == 1){
		if(sf->flags & SORCLOSE)
			remove = 1;
	}

	noperm = 0;
	if(remove && strcmp(sf->dir->user, up->env->user) != 0){
		noperm = 1;
		remove = 0;
	}
	if(remove)
		srvdelete(sf);
	srvchkref(sf);
	qunlock(&dev.l);

	if(noperm)
		error(Eperm);
}

static void
srvclose(Chan *c)
{
	srvclunk(c, 0);
}

static void
srvremove(Chan *c)
{
	srvclunk(c, 1);
}

/*
 * A request that will not be waited for any longer: its reader or
 * writer was interrupted (killed, or its 9P request flushed) before
 * the server answered.  The server was not told.  Its answer, when it
 * came, went into the reply channel's buffer and nowhere else, which
 * is right for a file that answers each request on its own; but a
 * server that hands out a stream (a posted 9P connection's replies,
 * post9p(2)) took the next piece of it for the request that had gone,
 * and the reader after it waited for a reply that had been spent.
 *
 * The reply channel now says so.  It has room for two: when the
 * request is given up, (nil, "interrupted") is put there (for a write,
 * (0, "interrupted")), which the server can take with a receive that
 * does not wait:
 *
 *	alt{
 *	<-rc =>	the reader has gone: keep what was for it
 *	* =>	rc <-= (data, nil);
 *	}
 *
 * A server that does not look is as before: its answer still goes into
 * the buffer, never waits, and reaches nobody.  Each request has a
 * channel of its own, so an answer that comes late is never a later
 * request's.
 *
 * The notice must not be the thing that fails.  Its text was made
 * here, where no memory meant no notice, and what the request needed
 * for its answer was made after the server had the request, where no
 * memory left the server answering nobody, untold; a request that was
 * interrupted as the server took it went the same way.  The requester
 * now has the text, and all else it needs, before the server has the
 * request, and tells of giving up from the moment it starts to send.
 * The notice is put only where there is room for it (there is, unless
 * the server has answered twice), so giving up never waits.
 */
static char Einterrupted[] = "interrupted";

static void
gaveup(Channel *rc, Channel *wc, String *gone)
{
	Sys_Rread rreply;
	Sys_Rwrite wreply;

	if(rc != nil && canput(rc)){
		rreply.t0 = H;
		rreply.t1 = gone;
		csend(rc, &rreply);
	}
	if(wc != nil && canput(wc)){
		wreply.t0 = 0;
		wreply.t1 = gone;
		csend(wc, &wreply);
	}
}

static void
addwaiting(SrvFile *sp, Pending *w)
{
	Pending *sw;

	sw = &sp->waitlist;
	w->next = sw;
	w->prev = sw->prev;
	sw->prev->next = w;
	sw->prev = w;
}

static void
delwaiting(Pending *w)
{
	w->next->prev = w->prev;
	w->prev->next = w->next;
	/*
	 * Left pointing at itself, so that taking it off again changes
	 * nothing. srvcancelreqs takes each waiter off the list and wakes
	 * it, and the waiter takes itself off on its way out: with its
	 * links as they were, that second time stored through them, into
	 * a neighbour that had since gone, a Pending on its own process's
	 * stack.
	 */
	w->next = w;
	w->prev = w;
}

static long
srvread(Chan *c, void *va, long count, vlong offset)
{
	Vm *home;
	int l;
	Heap * volatile h;
	Array *a;
	SrvFile *sp;
	Channel *rc;
	Channel *rd;
	String *gone;
	Pending wait;
	Sys_Rread * volatile r;
	Sys_FileIO_read req;

	if(c->qid.type & QTDIR){
		qlock(&dev.l);
		if(waserror()){
			qunlock(&dev.l);
			nexterror();
		}
		l = devdirread(c, va, count, 0, 0, srvgen);
		poperror();
		qunlock(&dev.l);
		return l;
	}

	sp = c->aux;

	home = srvacquire(sp);
	if(waserror()){
		srvrelease(home);
		nexterror();
	}

	if(sp->read == H)
		error(Ehungup);

	rc = cnewc(dev.Rread, movtmp, 2);	/* the answer, and "interrupted": see gaveup */
	ptradd(D2H(rc));
	if(waserror()){
		ptrdel(D2H(rc));
		destroy(rc);
		nexterror();
	}

	h = heap(dev.Rread);
	r = H2D(Sys_Rread *, h);
	ptradd(h);
	if(waserror()){
		ptrdel(h);
		destroy(r);
		nexterror();
	}

	gone = c2string(Einterrupted, strlen(Einterrupted));
	ptradd(D2H(gone));
	if(waserror()){
		ptrdel(D2H(gone));
		destroy(gone);
		nexterror();
	}

	noteflush(sp, &sp->rnote, c->fid);
	rd = sp->read;		/* noteflush can wait */
	if(rd == H)
		error(Ehungup);

	req.t0 = srvoffset(offset);
	req.t1 = count;
	req.t2 = c->fid;
	req.t3 = rc;

	wait.fid = c->fid;
	wait.rc = rc;
	wait.wc = nil;
	addwaiting(sp, &wait);
	if(waserror()){
		delwaiting(&wait);
		gaveup(rc, nil, gone);
		nexterror();
	}
	csend(rd, &req);
	crecv(rc, r);
	poperror();
	delwaiting(&wait);

	if(r->t1 != H)
		error(string2c(r->t1));

	a = r->t0;
	l = 0;
	if(a != H){
		l = a->len;
		if(l > count)
			l = count;
		memmove(va, a->data, l);
	}

	poperror();
	ptrdel(D2H(gone));
	destroy(gone);

	poperror();
	ptrdel(h);
	destroy(r);

	poperror();
	ptrdel(D2H(rc));
	destroy(rc);

	poperror();
	srvrelease(home);

	return l;
}

static long
srvwrite(Chan *c, void *va, long count, vlong offset)
{
	Vm *home;
	long l;
	Heap * volatile h;
	SrvFile *sp;
	Channel *wc;
	Channel *wr;
	String *gone;
	Array *data;
	Pending wait;
	Sys_Rwrite * volatile w;
	Sys_FileIO_write req;

	if(c->qid.type & QTDIR)
		error(Eperm);

	sp = c->aux;
	home = srvacquire(sp);
	if(waserror()){
		srvrelease(home);
		nexterror();
	}

	if(sp->write == H)
		error(Ehungup);

	wc = cnewc(dev.Rwrite, movtmp, 2);	/* the answer, and "interrupted": see gaveup */
	ptradd(D2H(wc));
	if(waserror()){
		ptrdel(D2H(wc));
		destroy(wc);
		nexterror();
	}

	h = heap(dev.Rwrite);
	w = H2D(Sys_Rwrite *, h);
	ptradd(h);
	if(waserror()){
		ptrdel(h);
		destroy(w);
		nexterror();
	}

	gone = c2string(Einterrupted, strlen(Einterrupted));
	ptradd(D2H(gone));
	if(waserror()){
		ptrdel(D2H(gone));
		destroy(gone);
		nexterror();
	}

	data = mem2array(va, count);
	ptradd(D2H(data));
	if(waserror()){
		ptrdel(D2H(data));
		destroy(data);
		nexterror();
	}

	noteflush(sp, &sp->wnote, c->fid);
	wr = sp->write;		/* noteflush can wait */
	if(wr == H)
		error(Ehungup);

	req.t0 = srvoffset(offset);
	req.t1 = data;
	req.t2 = c->fid;
	req.t3 = wc;

	wait.fid = c->fid;
	wait.rc = nil;
	wait.wc = wc;
	addwaiting(sp, &wait);
	if(waserror()){
		delwaiting(&wait);
		gaveup(nil, wc, gone);
		nexterror();
	}
	csend(wr, &req);
	crecv(wc, w);
	poperror();
	delwaiting(&wait);

	poperror();
	ptrdel(D2H(data));
	destroy(data);

	poperror();
	ptrdel(D2H(gone));
	destroy(gone);

	if(w->t1 != H)
		error(string2c(w->t1));
	poperror();
	ptrdel(h);
	l = w->t0;
	destroy(w);

	poperror();
	ptrdel(D2H(wc));
	destroy(wc);

	poperror();
	srvrelease(home);
	if(l < 0)
		l = 0;
	/* the server's count is its own: no more was written than was given */
	if(l > count)
		l = count;
	return l;
}

static void
srvretype(Channel *c, SrvFile *f, Type *t)
{
	Heap *h;

	h = D2H(c);
	freetype(h->t);
	h->t = t;
	t->ref++;
	c->aux = f;
}

int
srvf2c(char *dir, char *file, Sys_FileIO *io)
{
	SrvFile *s, *f;
	volatile struct { Chan *c; } c;

	c.c = nil;
	if(waserror()){
		cclose(c.c);
		return -1;
	}

	if(strchr(file, '/') != nil || strlen(file) >= 64 || strcmp(file, ".") == 0 || strcmp(file, "..") == 0)
		error(Efilename);

	c.c = namec(dir, Aaccess, 0, 0);
	if((c.c->qid.type&QTDIR) == 0 || devtab[c.c->type]->dc != 's')
		error("directory not a srv device");

	s = c.c->aux;

	qlock(&dev.l);
	if(waserror()){
		qunlock(&dev.l);
		nexterror();
	}
	for(f = s->entry; f != nil; f = f->entry){
		if(strcmp(f->name, file) == 0)
			error(Eexist);
	}

	f = malloc(sizeof(SrvFile));
	if(f == nil)
		error(Enomem);

	srvretype(io->read, f, Trdchan);
	srvretype(io->write, f, Twrchan);
	f->read = io->read;
	f->write = io->write;
	f->rnote.c = io->read;
	f->wnote.c = io->write;
	f->wnote.iswrite = 1;

	f->waitlist.next = &f->waitlist;
	f->waitlist.prev = &f->waitlist;

	kstrdup(&f->name, file);
	kstrdup(&f->user, up->env->user);
	f->perm = 0666 & (~0666 | (s->perm & 0666));
	f->length = 0;
	f->ref = 2;
	mkqid(&f->qid, dev.pathgen++, 0, QTFILE);

	f->entry = s->entry;
	s->entry = f;
	s->ref++;
	f->dir = s;
	f->vm = up->vm;	/* its channels are this VM's: srvacquire */
	poperror();
	qunlock(&dev.l);

	cclose(c.c);
	poperror();

	return 0;
}

/*
 * The Dev table is the one thing that had to be rewritten rather than
 * moved, because the two kernels do not have the same one.
 *
 * emu's Dev begins name, init, attach; a native Dev begins name,
 * RESET, init, SHUTDOWN, attach. The initialiser here is positional,
 * so leaving emu's order in place silently shifted every entry by two
 * -- attach became init, walk became attach, and so on down the whole
 * table. The compiler caught it as a wall of incompatible function
 * pointer types; had the signatures happened to agree it would have
 * been a device that answered every request with the wrong operation.
 *
 * emu's srvinit is what a native kernel calls RESET: the once-per-boot
 * initialisation. devinit is the per-attach no-op, and devshutdown
 * the teardown this device does not need.
 */
Dev srvdevtab = {
	's',
	"srv",

	srvinit,		/* reset, which is what emu calls init */
	devinit,
	devshutdown,
	srvattach,
	srvwalk,
	srvstat,
	srvopen,
	devcreate,
	srvclose,
	srvread,
	devbread,
	srvwrite,
	devbwrite,
	srvremove,
	srvwstat
};
