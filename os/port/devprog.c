/*
 * #p -- the process device.
 *
 * IMPORTED from emu/port/devprog.c. The emulator and a native kernel
 * serve the same device over the same Dis machinery -- Prog, Osenv and
 * the module tables all come from libinterp either way -- so the only
 * change needed was this include preamble: emu's sources start at
 * dat.h, which pulls in its own lib9.h, while a native kernel leads
 * with u.h and takes lib.h and error.h from os/port.
 *
 * It is what makes a shell possible. sh's waitfd() opens
 * "#p/<pid>/wait" to reap its children and calls panic() when that
 * fails, so without this device the shell loads, resolves every
 * library, and then dies before its first prompt.
 *
 * Two renames were needed beyond the includes: emu spells the
 * rendezvous primitives Sleep()/Wakeup(), and a native kernel spells
 * them sleep()/wakeup(). The signatures are identical.
 *
 * Built with the libinterp flags rather than the kernel's, because it
 * formats Dis values: reading /prog/N/heap prints a REAL with %g, and
 * Dis has a floating point type. That is the same reason libinterp
 * itself is built with FP, and it is safe here for the same reason --
 * no interrupt path touches FP, and procsave/procrestore preserve it
 * across a context switch.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"interp.h"
#include	"isa.h"
#include	"runt.h"

/*
 * Enable the heap device for environments that allow debugging =>
 * Must be 1 for a production environment.
 */
int	SECURE = 1;

enum
{
	Qdir,
	Qctl,
	Qdbgctl,
	Qheap,
	Qns,
	Qnsgrp,
	Qpgrp,
	Qstack,
	Qstatus,
	Qtext,
	Qwait,
	Qfd,
	Qexception,
	Qgrpwait,
};

/*
 * must be in same order as enum
 */
Dirtab progdir[] =
{
	"ctl",		{Qctl},		0,			0200,
	"dbgctl",	{Qdbgctl},	0,			0600,
	"heap",		{Qheap},	0,			0600,
	"ns",		{Qns},		0,			0400,
	"nsgrp",	{Qnsgrp},	0,			0444,
	"pgrp",		{Qpgrp},	0,			0444,
	"stack",	{Qstack},	0,			0400,
	"status",	{Qstatus},	0,			0444,
	"text",		{Qtext},	0,			0000,
	"wait",		{Qwait},	0,			0400,
	"fd",		{Qfd},		0,			0400,
	"exception",	{Qexception},	0,	0400,
	"grpwait",	{Qgrpwait},	0,	0444,
};

enum
{
	CMkill,
	CMkillgrp,
	CMkilltree,
	CMrestricted,
	CMexceptions,
	CMprivate
};

static
Cmdtab progcmd[] = {
	CMkill,	"kill",	1,
	CMkillgrp,	"killgrp",	1,
	CMkilltree,	"killtree",	1,
	CMrestricted, "restricted", 1,
	CMexceptions, "exceptions", 2,
	CMprivate, "private",	1,
};

enum
{
	CDstep,
	CDtoret,
	CDcont,
	CDstart,
	CDstop,
	CDunstop,
	CDmaim,
	CDbpt
};

static
Cmdtab progdbgcmd[] = {
	CDstep,	"step",	0,	/* known below to be first, to cope with stepN */
	CDtoret,	"toret",	1,
	CDcont,	"cont",	1,
	CDstart,	"start",	1,
	CDstop,	"stop",	1,
	CDunstop,	"unstop",	1,
	CDmaim,	"maim",	1,
	CDbpt,	"bpt",	4,
};

typedef struct Heapqry Heapqry;
struct Heapqry
{
	char	fmt;
	ulong	addr;
	ulong	module;
	int	count;
};

typedef struct Bpt	Bpt;

struct Bpt
{
	Bpt	*next;
	int	pc;
	char	*file;
	char	path[1];
};

typedef struct Progctl Progctl;
struct Progctl
{
	Rendez	r;
	int	ref;
	Proc	*debugger;	/* waiting for dbgxec */
	char	*msg;		/* reply from dbgxec */
	int	step;		/* instructions to try */
	int	stop;		/* stop running the program */
	Bpt*	bpts;		/* active breakpoints */
	Queue*	q;		/* status queue */
};

#define	QSHIFT		4		/* location in qid of pid */
#define	QID(q)		(((ulong)(q).path&0x0000000F)>>0)
#define QPID(pid)	(((pid)<<QSHIFT))
#define	PID(q)		((q).vers)
#define PATH(q)		((ulong)(q).path&~((1<<QSHIFT)-1))

static char *progstate[] =			/* must correspond to include/interp.h */
{
	"alt",				/* blocked in alt instruction */
	"send",				/* waiting to send */
	"recv",				/* waiting to recv */
	"debug",			/* debugged */
	"ready",			/* ready to be scheduled */
	"release",			/* interpreter released */
	"exiting",			/* exit because of kill or error */
	"broken",			/* thread crashed */
};

static	void	dbgstep(Progctl*, Prog*, int);
static	void	dbgstart(Prog*);
static	void	freebpts(Bpt*);
static	Bpt*	delbpt(Bpt*, char*, int);
static	Bpt*	setbpt(Bpt*, char*, int);
/*
 * snprint for a listing made in the reader's buffer, a line at a time:
 * no room is 0, not snprint's -1. Added to the count, the -1 moved it
 * back, and the next line was written before the buffer (a nil write
 * and the native kernel's panic, from a /prog read of 0 or 1 bytes;
 * tools/nativefuzz).
 */
static int
psnprint(char *s, int n, char *fmt, ...)
{
	va_list arg;

	if(n <= 0)
		return 0;
	va_start(arg, fmt);
	n = vsnprint(s, n, fmt, arg);
	va_end(arg);
	return n < 0? 0: n;
}

enum { Nsline = 2048 };	/* the most of a line of ns */
static	int	mntscan(Mntwalk*, Pgrp*, char*, int);
static	int	progdot(Pgrp*, char*, int);
extern	Type	*Trdchan;
extern	Type	*Twrchan;
static  char 	Emisalign[] = "misaligned address";

static /*
 * A Prog is touched only under its own VM's interpreter (#944): its
 * VM may be running it, or freeing it, on another core. So devprog
 * takes the VM of the Prog it is asked about, and gives the caller's
 * own back after. pid 0 (the directory) needs no particular VM.
 */
static void
pacquire(ulong pid)
{
	Vm *v;

	v = nil;
	if(pid != 0)
		v = pidvm(pid);
	up->vmhome = up->vm;
	if(v != nil)
		up->vm = v;
	acquire();
}

static void
prelease(void)
{
	release();
	up->vm = up->vmhome;
}

int
proggen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid qid;
	Prog *p;
	char *e;
	Osenv *o;
	ulong pid, path, perm, len;

	USED(ntab);

	if(s == DEVDOTDOT){
		mkqid(&qid, Qdir, 0, QTDIR);
		devdir(c, qid, "#p", 0, eve, DMDIR|0555, dp);
		return 1;
	}

	if((ulong)c->qid.path == Qdir) {
		if(name != nil){
			/* ignore s and use name to find pid */
			pid = strtoul(name, &e, 0);
			if(pid == 0 || *e != '\0')
				return -1;
			pacquire(pid);
			p = progpid(pid);
			if(p == nil){
				prelease();
				return -1;
			}
		}else{
			pid = progpidn(s);
			if(pid < 0)
				return -1;
			pacquire(pid);
			p = progpid(pid);
			if(p == nil) {
				prelease();
				return -1;
			}
			pid = p->pid;
		}
		o = p->osenv;
		sprint(up->genbuf, "%lud", pid);
		if(name != nil && strcmp(name, up->genbuf) != 0){
			prelease();
			return -1;
		}
		mkqid(&qid, pid<<QSHIFT, pid, QTDIR);
		devdir(c, qid, up->genbuf, 0, o->user, DMDIR|0555, dp);
		prelease();
		return 1;
	}

	if(s >= nelem(progdir))
		return -1;
	tab = &progdir[s];
	path = PATH(c->qid);

	pacquire(PID(c->qid));
	p = progpid(PID(c->qid));
	if(p == nil) {
		prelease();
		return -1;
	}

	o = p->osenv;

	perm = tab->perm;
	if((perm & 7) == 0)
		perm = (perm|(perm>>3)|(perm>>6)) & o->pgrp->progmode;

	len = tab->length;
	mkqid(&qid, path|tab->qid.path, c->qid.vers, QTFILE);
	devdir(c, qid, tab->name, len, o->user, perm, dp);
	prelease();
	return 1;
}

static Chan*
progattach(char *spec)
{
	return devattach('p', spec);
}

static Walkqid*
progwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, 0, 0, proggen);
}

static int
progstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, 0, 0, proggen);
}

static Chan*
progopen(Chan *c, int omode)
{
	Prog *p;
	Osenv *o;
	Progctl *ctl;
	int perm;

	if(c->qid.type & QTDIR)
		return devopen(c, omode, 0, 0, proggen);

	pacquire(PID(c->qid));
	if (waserror()) {
		prelease();
		nexterror();
	}
	p = progpid(PID(c->qid));
	if(p == nil)
		error(Ethread);
	o = p->osenv;
	perm = progdir[QID(c->qid)-1].perm;
	if((perm & 7) == 0)
		perm = (perm|(perm>>3)|(perm>>6)) & o->pgrp->progmode;
	devpermcheck(o->user, perm, omode);
	omode = openmode(omode);

	switch(QID(c->qid)){
	default:
		error(Egreg);
	case Qnsgrp:
	case Qpgrp:
	case Qtext:
	case Qstatus:
	case Qstack:
	case Qctl:
	case Qfd:
	case Qexception:
		break;
	case Qwait:
		c->aux = qopen(1024, Qmsg, nil, nil);
		if(c->aux == nil)
			error(Enomem);
		o->childq = c->aux;
		break;
	case Qgrpwait:
		/* waits for the group the Prog is in now to have no Prog left */
		c->aux = qopen(64, Qmsg, nil, nil);
		if(c->aux == nil)
			error(Enomem);
		if(p->group != nil)
			grpwaitadd(p->group->id, c->aux);
		else
			qproduce(c->aux, "0", 1);
		break;
	case Qns:
		c->aux = malloc(sizeof(Mntwalk));
		if(c->aux == nil)
			error(Enomem);
		break;
	case Qheap:
		if(SECURE || p->group->flags&Pprivatemem || omode != ORDWR)
			error(Eperm);
		c->aux = malloc(sizeof(Heapqry));
		if(c->aux == nil)
			error(Enomem);
		break;
	case Qdbgctl:
		if(SECURE || p->group->flags&Pprivatemem || omode != ORDWR)
			error(Eperm);
		ctl = malloc(sizeof(Progctl));
		if(ctl == nil)
			error(Enomem);
		ctl->q = qopen(1024, Qmsg, nil, nil);
		if(ctl->q == nil) {
			free(ctl);
			error(Enomem);
		}
		ctl->bpts = nil;
		ctl->ref = 1;
		c->aux = ctl;
		break;
	}
	if(p->state != Pexiting)
		c->qid.vers = p->pid;

	poperror();
	prelease();
	c->offset = 0;
	c->mode = omode;
	c->flag |= COPEN;
	return c;
}

static int
progwstat(Chan *c, uchar *db, int n)
{
	Dir d;
	Prog *p;
	char *u;
	Osenv *o;

	if(c->qid.type&QTDIR)
		error(Eperm);
	pacquire(PID(c->qid));
	p = progpid(PID(c->qid));
	if(p == nil) {
		prelease();
		error(Ethread);
	}

	u = up->env->user;
	o = p->osenv;
	if(strcmp(u, o->user) != 0 && strcmp(u, eve) != 0) {
		prelease();
		error(Eperm);
	}

	n = convM2D(db, n, &d, nil);
	if(n == 0){
		prelease();
		error(Eshortstat);
	}
	if(d.mode != ~0UL)
		o->pgrp->progmode = d.mode&0777;
	prelease();
	return n;
}

static void
closedbgctl(Progctl *ctl, Prog *p)
{
	Osenv *o;

	if(ctl->ref-- > 1)
		return;
	freebpts(ctl->bpts);
	if(p != nil){
		o = p->osenv;
		if(o->debug == ctl){
			o->debug = nil;
			p->xec = xec;
		}
	}
	qfree(ctl->q);
	free(ctl);
}

static void
progclose(Chan *c)
{
	Progctl *ctl;

	switch(QID(c->qid)) {
	case Qns:
	case Qheap:
		free(c->aux);
		break;
	case Qdbgctl:
		if((c->flag & COPEN) == 0)
			return;
		ctl = c->aux;
		pacquire(PID(c->qid));
		closedbgctl(ctl, progpid(PID(c->qid)));
		prelease();
		break;
	case Qwait:
		vmclearwaitq(c->aux);	/* every VM's Progs, each VM in one go (dis.c) */
		qfree(c->aux);
		break;
	case Qgrpwait:
		if((c->flag & COPEN) == 0)
			return;
		acquire();
		grpwaitdel(c->aux);
		release();
		qfree(c->aux);
		break;
	}
}

static int
progsize(Prog *p)
{
	int size;
	Frame *f;
	uchar *fp;
	Modlink *m;

	m = p->reg.M;
	size = 0;
	if(m->MP != H)
		size += hmsize(D2H(m->MP));
	/*
	 * For JIT-compiled modules m->prog points into the executable
	 * code arena, not pool memory (freemod has the matching guard).
	 * msize() on it faults the allocator ("alloc:D2B") under the
	 * pool lock, and the fault audit then spins on that same lock
	 * while this kproc holds the VM token — wedging the whole
	 * emulator on the first /prog status read of a compiled prog.
	 * Skip the native-code size term instead.
	 */
	if(m->prog != nil && !m->compiled)
		size += msize(m->prog);

	fp = p->reg.FP;
	while(fp != nil) {
		f = (Frame*)fp;
		fp = f->fp;
		if(f->mr != nil) {
			if(f->mr->MP != H)
				size += hmsize(D2H(f->mr->MP));
			if(f->mr->prog != nil && !f->mr->compiled)
				size += msize(f->mr->prog);
		}
		if(f->t == nil)
			size += msize(SEXTYPE(f));
	}
	return size/1024;
}

static int
progqidwidth(Chan *c)
{
	char buf[32];

	return sprint(buf, "%lud", c->qid.vers);
}

int
progfdprint(Chan *c, int fd, int w, char *s, int ns)
{
	int n;

	if(w == 0)
		w = progqidwidth(c);
	n = snprint(s, ns, "%3d %.2s %C %4ld (%.16llux %*lud %.2ux) %5ld %8lld %s\n",
		fd,
		&"r w rw"[(c->mode&3)<<1],
		devtab[c->type]->dc, c->dev,
		c->qid.path, w, c->qid.vers, c->qid.type,
		c->iounit, c->offset, c->name != nil? c->name->s : "");
	if(n < 0)
		n = 0;
	return n;
}

/*
 * A Prog's fd table, copied with a reference to each Chan, under its
 * VM; printed, with its dot, and its Chans closed, with the VM let go.
 * Nothing that takes a name space's lock is done holding a VM: a
 * mount waits for a Mhead's lock holding its name space's, and a union
 * directory's read holds the Mhead's across a 9P read that may never
 * be answered, so a read of fd or ns stopped a VM for good
 * (tools/nativefuzz). Natively the table is locked as it is copied:
 * holding the Prog's VM does not hold its fd table, which vm(1) shares
 * with a Prog in another VM.
 */
typedef struct Fdsnap Fdsnap;
struct Fdsnap
{
	int	n;
	Chan**	c;
	int*	fd;
};

static void
fdsnap(Fgrp *f, Fdsnap *s)
{
	int i, m;
	Chan *c;

	s->n = 0;
	lock(&f->l);
	m = f->maxfd+1;
	unlock(&f->l);
	if(m < 1)
		m = 1;
	s->c = malloc(m*sizeof(Chan*));
	s->fd = malloc(m*sizeof(int));
	if(s->c == nil || s->fd == nil){
		free(s->c);
		free(s->fd);
		s->c = nil;
		s->fd = nil;
		error(Enomem);
	}
	lock(&f->l);
	for(i = 0; i <= f->maxfd && s->n < m; i++) {
		c = f->fd[i];
		if(c == nil)
			continue;
		incref(&c->r);
		s->c[s->n] = c;
		s->fd[s->n++] = i;
	}
	unlock(&f->l);
}

static void
fdsnapfree(Fdsnap *s)
{
	int i;

	for(i = 0; i < s->n; i++)
		cclose(s->c[i]);
	free(s->c);
	free(s->fd);
	s->n = 0;
	s->c = nil;
	s->fd = nil;
}

/*
 * The listing is made whole in a buffer of its own, sized for it, and
 * the read's part taken from it. Made in the reader's buffer, a line
 * that did not fit was snprint's -1 (no room), added to the count: the
 * next line went before the buffer, over the heap.
 */
static int
progfds(Pgrp *pg, Fdsnap *s, char *va, int count, vlong offset)
{
	int n, i, w, ww, size, k;
	char *buf;

	size = 1024;
	for(i = 0; i < s->n; i++)
		size += 96 + (s->c[i]->name != nil? strlen(s->c[i]->name->s) : 0);
	buf = malloc(size);
	if(buf == nil)
		error(Enomem);
	k = progdot(pg, buf, 1000);
	buf[k++] = '\n';
	buf[k] = 0;
	/* compute width of qid.path */
	w = 0;
	for(i = 0; i < s->n; i++) {
		ww = progqidwidth(s->c[i]);
		if(ww > w)
			w = ww;
	}
	for(i = 0; i < s->n && k < size - 1; i++)
		k += progfdprint(s->c[i], s->fd[i], w, buf+k, size-k);
	buf[k] = 0;
	n = readstr(offset, va, count, buf);
	free(buf);
	return n;
}

Inst *
pc2dispc(Inst *pc, Module *mod)
{
	ulong l, u, m, v;
	ulong *tab = mod->pctab;

	v = (ulong)pc - (ulong)mod->prog;
	l = 0;
	u = mod->nprog-1;
	while(l < u){
		m = (l+u+1)/2;
		if(tab[m] < v)
			l = m;
		else if(tab[m] > v)
			u = m-1;
		else
			l = u = m;
	}
	if(l == u && tab[u] <= v && u != mod->nprog-1 && tab[u+1] > v)
		return &mod->prog[u];
	return 0;
}

static int
progstack(REG *reg, int state, char *va, int count, long offset)
{
	int n;
	Frame *f;
	Inst *pc;
	uchar *fp;
	Modlink *m;

	n = 0;
	m = reg->M;
	fp = reg->FP;
	pc = reg->PC;

	/*
	 * all states other than debug and ready block,
	 * but interp has already advanced the PC
	 */
	if(!m->compiled && state != Pready && state != Pdebug && pc > m->prog)
		pc--;
	if(m->compiled && m->m->pctab != nil)
		pc = pc2dispc(pc, m->m);

	while(fp != nil) {
		f = (Frame*)fp;
		n += psnprint(va+n, count-n, "%.8lux %.8lux %.8lux %.8lux %d %s\n",
				(ulong)f,		/* FP */
				(ulong)(pc - m->prog),	/* PC in dis instructions */
				(ulong)m->MP,		/* MP */
				(ulong)m->prog,	/* Code for module */
				m->compiled && m->m->pctab == nil,	/* True if native assembler: fool stack utility for now */
				m->m->path);	/* File system path */

		if(offset > 0) {
			offset -= n;
			if(offset < 0) {
				memmove(va, va+n+offset, -offset);
				n = -offset;
			}
			else
				n = 0;
		}

		pc = f->lr;
		fp = f->fp;
		if(f->mr != nil)
			m = f->mr;
		if(!m->compiled)
			pc--;
		else if(m->m->pctab != nil)
			pc = pc2dispc(pc, m->m)-1;
	}
	return n;
}

static int
calldepth(REG *reg)
{
	int n;
	uchar *fp;

	n = 0;
	for(fp = reg->FP; fp != nil; fp = ((Frame*)fp)->fp)
		n++;
	return n;
}

static int
progheap(Heapqry *hq, char *va, int count, ulong offset)
{
	WORD *w;
	void *p;
	List *hd;
	Array *a;
	char *fmt, *str;
	Module *m;
	Modlink *ml;
	Channel *c;
	ulong addr;
	String *ss;
	union { REAL r; LONG l; WORD w[2]; } rock;
	int i, s, n, len, signed_off;
	Type *t;

	n = 0;
	s = 0;
	signed_off = offset;
	addr = hq->addr;
	for(i = 0; i < hq->count; i++) {
		switch(hq->fmt) {
		case 'W':
			if(addr & 3)
				return -1;
			n += psnprint(va+n, count-n, "%d\n", *(WORD*)addr);
			s = sizeof(WORD);
			break;
		case 'B':
			n += psnprint(va+n, count-n, "%d\n", *(BYTE*)addr);
			s = sizeof(BYTE);
			break;
		case 'V':
			if(addr & 3)
				return -1;
			w = (WORD*)addr;
			rock.w[0] = w[0];
			rock.w[1] = w[1];
			n += psnprint(va+n, count-n, "%lld\n", rock.l);
			s = sizeof(LONG);
			break;
		case 'R':
			if(addr & 3)
				return -1;
			w = (WORD*)addr;
			rock.w[0] = w[0];
			rock.w[1] = w[1];
			n += psnprint(va+n, count-n, "%g\n", rock.r);
			s = sizeof(REAL);
			break;
		case 'I':
			if(addr & 3)
				return -1;
			for(m = modules; m != nil; m = m->link)
				if(m == (Module*)hq->module)
					break;
			if(m == nil)
				error(Ebadctl);
			addr = (ulong)(m->prog+addr);
			n += psnprint(va+n, count-n, "%D\n", (Inst*)addr);
			s = sizeof(Inst);
			break;
		case 'P':
			if(addr & 3)
				return -1;
			p = *(void**)addr;
			fmt = "nil\n";
			if(p != H)
				fmt = "%lux\n";
			n += psnprint(va+n, count-n, fmt, p);
			s = sizeof(WORD);
			break;
		case 'L':
			if(addr & 3)
				return -1;
			hd = *(List**)addr;
			if(hd == H || D2H(hd)->t != &Tlist)
				return -1;
			n += psnprint(va+n, count-n, "%lux.%lux\n", (ulong)&hd->tail, (ulong)hd->data);
			s = sizeof(WORD);
			break;
		case 'A':
			if(addr & 3)
				return -1;
			a = *(Array**)addr;
			if(a == H)
				n += psnprint(va+n, count-n, "nil\n");
			else {
				if(D2H(a)->t != &Tarray)
					return -1;
				n += psnprint(va+n, count-n, "%d.%lux\n", a->len, (ulong)a->data);
			}
			s = sizeof(WORD);
			break;
		case 'C':
			if(addr & 3)
				return -1;
			ss = *(String**)addr;
			if(ss == H)
				ss = &snil;
			else
			if(D2H(ss)->t != &Tstring)
				return -1;
			n += psnprint(va+n, count-n, "%d.", abs(ss->len));
			str = string2c(ss);
			len = strlen(str);
			if(count-n < len)
				len = count-n;
			if(len > 0) {
				memmove(va+n, str, len);
				n += len;
			}
			break;
		case 'M':
			if(addr & 3)
				return -1;
			ml = *(Modlink**)addr;
			fmt = ml == H ? "nil\n" : "%lux\n";
			n += psnprint(va+n, count-n, fmt, ml->MP);
			s = sizeof(WORD);
			break;
		case 'c':
			if(addr & 3)
				return -1;
			c = *(Channel**)addr;
			if(c == H)
				n += psnprint(va+n, count-n, "nil\n");
			else{
				t = D2H(c)->t;
				if(t != &Tchannel && t != Trdchan && t != Twrchan)
					return -1;
				if(c->buf == H)
					n += psnprint(va+n, count-n, "0.%lux\n", (ulong)c);
				else
					n += psnprint(va+n, count-n, "%d.%lux.%d.%d\n", c->buf->len, (ulong)c->buf->data, c->front, c->size);
			}
			break;
			
		}
		addr += s;
		if(signed_off > 0) {
			signed_off -= n;
			if(signed_off < 0) {
				memmove(va, va+n+signed_off, -signed_off);
				n = -signed_off;
			}
			else
				n = 0;
		}
	}
	return n;
}

WORD
modstatus(REG *r, char *ptr, int len)
{
	Inst *PC;
	Frame *f;

	if(r->M->m->name[0] == '$') {
		f = (Frame*)r->FP;
		snprint(ptr, len, "%s[%s]", f->mr->m->name, r->M->m->name);
		if(f->mr->compiled)
			return (WORD)f->lr;
		return f->lr - f->mr->prog;
	}
	memmove(ptr, r->M->m->name, len);
	if(r->M->compiled)
		return (WORD)r->PC;
	PC = r->PC;
	/* should really check for blocked states */
	if(PC > r->M->prog)
		PC--;
	return PC - r->M->prog;
}

static void
int2flag(int flag, char *s)
{
	if(flag == 0){
		*s = '\0';
		return;
	}
	*s++ = '-';
	if(flag & MAFTER)
		*s++ = 'a';
	if(flag & MBEFORE)
		*s++ = 'b';
	if(flag & MCREATE)
		*s++ = 'c';
	if(flag & MREADONLY)
		*s++ = 'R';
	if(flag & MCACHE)
		*s++ = 'C';
	*s = '\0';
}

static char*
progtime(ulong msec, char *buf, char *ebuf)
{
	int tenths, sec;

	tenths = msec/100;
	sec = tenths/10;
	seprint(buf, ebuf, "%4d:%2.2d.%d", sec/60, sec%60, tenths%10);
	return buf;
}

static long
progread(Chan *c, void *va, long n, vlong offset)
{
	int i;
	Prog *p;
	Osenv *o;
	Mntwalk *mw;
	ulong grpid;
	char *a = va;
	char *nsl;
	Pgrp *pg;
	Fdsnap fs;
	Progctl *ctl;
	char mbuf[64], timebuf[12];

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, proggen);

	switch(QID(c->qid)){
	case Qdbgctl:
		ctl = c->aux;
		return qread(ctl->q, va, n);
	case Qstatus:
		pacquire(PID(c->qid));
		p = progpid(PID(c->qid));
		if(p == nil || p->state == Pexiting || p->reg.M == H) {
			prelease();
			snprint(up->genbuf, sizeof(up->genbuf), "%8lud %8d %10s %s %10s %5dK %s",
				PID(c->qid),
				0,
				eve,
				progtime(0, timebuf, timebuf+sizeof(timebuf)),
				progstate[Pexiting],
				0,
				"[$Sys]");
			return readstr(offset, va, n, up->genbuf);
		}
		modstatus(&p->reg, mbuf, sizeof(mbuf));
		o = p->osenv;
		snprint(up->genbuf, sizeof(up->genbuf), "%8d %8d %10s %s %10s %5dK %s",
			p->pid,
			p->group!=nil? p->group->id: 0,
			o->user,
			progtime(p->ticks, timebuf, timebuf+sizeof(timebuf)),
			progstate[p->state],
			progsize(p),
			mbuf);
		prelease();
		return readstr(offset, va, n, up->genbuf);
	case Qwait:
	case Qgrpwait:
		return qread(c->aux, va, n);
	case Qns:
		pacquire(PID(c->qid));
		if(waserror()){
			prelease();
			nexterror();
		}
		p = progpid(PID(c->qid));
		if(p == nil)
			error(Ethread);
		mw = c->aux;
		if(mw->cddone){
			poperror();
			prelease();
			return 0;
		}
		o = p->osenv;
		/* the name space, held, its locks taken with the VM let go: see fdsnap */
		pg = o->pgrp;
		incref(&pg->r);
		poperror();
		prelease();
		/*
		 * A line, made in a buffer of its own and as much of it given
		 * as the read has room for. Made in the reader's, a read too
		 * short for "cd " had snprint's -1 (no room) added to its
		 * count, and dot's name went before the buffer (a nil write,
		 * the kernel's panic; tools/nativefuzz). The mount is found and
		 * its line made under the name space's lock: a Mount kept past
		 * the lock can be freed by an unmount on another core.
		 */
		if(n <= 0){
			closepgrp(pg);
			return 0;
		}
		nsl = malloc(Nsline);
		if(nsl == nil){
			closepgrp(pg);
			error(Enomem);
		}
		i = mntscan(mw, pg, nsl, Nsline);
		if(i < 0) {
			mw->cddone = 1;
			i = snprint(nsl, Nsline, "cd ");
			i += progdot(pg, nsl+i, Nsline-i-2);
			nsl[i++] = '\n';
		}
		if(i > n)
			i = n;
		memmove(a, nsl, i);
		free(nsl);
		closepgrp(pg);
		return i;
	case Qnsgrp:
		pacquire(PID(c->qid));
		p = progpid(PID(c->qid));
		if(p == nil) {
			prelease();
			error(Ethread);
		}
		grpid = ((Osenv *)p->osenv)->pgrp->pgrpid;
		prelease();
		return readnum(offset, va, n, grpid, NUMSIZE);
	case Qpgrp:
		pacquire(PID(c->qid));
		p = progpid(PID(c->qid));
		if(p == nil) {
			prelease();
			error(Ethread);
		}
		grpid = p->group!=nil? p->group->id: 0;
		prelease();
		return readnum(offset, va, n, grpid, NUMSIZE);
	case Qstack:
		pacquire(PID(c->qid));
		p = progpid(PID(c->qid));
		/* M is H in a Prog with no frame left to run: nothing to show (a nil walk of H, the kernel's panic) */
		if(p == nil || p->state == Pexiting || p->reg.M == H) {
			prelease();
			error(Ethread);
		}
		if(p->state == Pready) {
			prelease();
			error(Estopped);
		}
		n = progstack(&p->reg, p->state, va, n, offset);
		prelease();
		return n;
	case Qheap:
		pacquire(PID(c->qid));
		if(waserror()){
			prelease();
			nexterror();
		}
		n = progheap(c->aux, va, n, offset);
		if(n == -1)
			error(Emisalign);
		poperror();
		prelease();
		return n;
	case Qfd:
		pacquire(PID(c->qid));
		if(waserror()) {
			prelease();
			nexterror();
		}
		p = progpid(PID(c->qid));
		if(p == nil)
			error(Ethread);
		o = p->osenv;
		fdsnap(o->fgrp, &fs);
		pg = o->pgrp;
		incref(&pg->r);
		poperror();
		prelease();
		if(waserror()) {
			fdsnapfree(&fs);
			closepgrp(pg);
			nexterror();
		}
		n = progfds(pg, &fs, va, n, offset);
		poperror();
		fdsnapfree(&fs);
		closepgrp(pg);
		return n;
	case Qexception:
		pacquire(PID(c->qid));
		p = progpid(PID(c->qid));
		if(p == nil) {
			prelease();
			error(Ethread);
		}
		if(p->exstr == nil)
			up->genbuf[0] = 0;
		else
			snprint(up->genbuf, sizeof(up->genbuf), p->exstr);
		prelease();
		return readstr(offset, va, n, up->genbuf);
	}
	error(Egreg);
	return 0;
}

/* the next mount after mw's, as a line of ns; -1 when there is none */
static int
mntscan(Mntwalk *mw, Pgrp *pg, char *a, int n)
{
	Mount *t;
	Mhead *f;
	int i, r;
	ulong best;
	char flag[10];

	r = -1;
	best = 0;
	rlock(&pg->ns);
	for(i = 0; i < MNTHASH; i++) {
		for(f = pg->mnthash[i]; f; f = f->hash) {
			rlock(&f->lock);
			for(t = f->mount; t; t = t->next) {
				if(mw->started && t->mountid <= mw->id)
					continue;
				if(r >= 0 && t->mountid >= best)
					continue;
				best = t->mountid;
				int2flag(t->mflag, flag);
				if(strcmp(t->to->name->s, "#M") == 0)
					r = snprint(a, n, "mount %s %s %s %s\n", flag,
						t->to->mchan->name->s,
						f->from->name->s, t->spec? t->spec : "");
				else
					r = snprint(a, n, "bind %s %s %s\n", flag,
						t->to->name->s, f->from->name->s);
			}
			runlock(&f->lock);
		}
	}
	runlock(&pg->ns);
	if(r >= 0) {
		mw->started = 1;
		mw->id = best;
	}
	return r;
}

/* dot's name, read under the lock chdir changes it under: its old Chan is closed after */
static int
progdot(Pgrp *pg, char *va, int count)
{
	int n;

	rlock(&pg->ns);
	n = readstr(0, va, count, pg->dot->name->s);
	runlock(&pg->ns);
	return n;
}

static long
progwrite(Chan *c, void *va, long n, vlong offset)
{
	Prog *p, *f;
	Heapqry *hq;
	char buf[512];
	Progctl *ctl;
	char *b;
	int i, pc;
	Cmdbuf *cb;
	Cmdtab *ct;

	USED(offset);
	USED(va);

	if(c->qid.type & QTDIR)
		error(Eisdir);

	pacquire(PID(c->qid));
	if(waserror()) {
		prelease();
		nexterror();
	}
	p = progpid(PID(c->qid));
	if(p == nil)
		error(Ethread);

	switch(QID(c->qid)){
	case Qctl:
		cb = parsecmd(va, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		ct = lookupcmd(cb, progcmd, nelem(progcmd));
		switch(ct->index){
		case CMkillgrp:
			killgrp(p, "killed");
			break;
		case CMkilltree:
			killgrptree(p, "killed");
			break;
		case CMkill:
			killprog(p, "killed");
			break;
		case CMrestricted:
			p->flags |= Prestrict;
			break;
		case CMexceptions:
			if(p->group->id != p->pid)
				error(Eperm);
			if(strcmp(cb->f[1], "propagate") == 0)
				p->flags |= Ppropagate;
			else if(strcmp(cb->f[1], "notifyleader") == 0)
				p->flags |= Pnotifyleader;
			else
				error(Ebadctl);
			break;
		case CMprivate:
			p->group->flags |= Pprivatemem;
			break;
		}
		poperror();
		free(cb);
		break;
	case Qdbgctl:
		cb = parsecmd(va, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf == 1 && strncmp(cb->f[0], "step", 4) == 0)
			ct = progdbgcmd;
		else
			ct = lookupcmd(cb, progdbgcmd, nelem(progdbgcmd));
		switch(ct->index){
		case CDstep:
			if(cb->nf == 1)
				i = strtoul(cb->f[0]+4, nil, 0);
			else
				i = strtoul(cb->f[1], nil, 0);
			dbgstep(c->aux, p, i);
			break;
		case CDtoret:
			f = currun();
			i = calldepth(&p->reg);
			while(f->kill == nil) {
				dbgstep(c->aux, p, 1024);
				if(i > calldepth(&p->reg))
					break;
			}
			break;
		case CDcont:
			f = currun();
			while(f->kill == nil)
				dbgstep(c->aux, p, 1024);
			break;
		case CDstart:
			dbgstart(p);
			break;
		case CDstop:
			ctl = c->aux;
			ctl->stop = 1;
			break;
		case CDunstop:
			ctl = c->aux;
			ctl->stop = 0;
			break;
		case CDbpt:
			pc = strtoul(cb->f[3], nil, 10);
			ctl = c->aux;
			if(strcmp(cb->f[1], "set") == 0)
				ctl->bpts = setbpt(ctl->bpts, cb->f[2], pc);
			else if(strcmp(cb->f[1], "del") == 0)
				ctl->bpts = delbpt(ctl->bpts, cb->f[2], pc);
			else
				error(Ebadctl);
			break;
		case CDmaim:
			p->kill = "maim";
			break;
		}
		poperror();
		free(cb);
		break;
	case Qheap:
		/*
		 * Heap query:
		 *	addr.Fn
		 *	pc+module.In
		 */
		i = n;
		if(i > sizeof(buf)-1)
			i = sizeof(buf)-1;
		memmove(buf, va, i);
		buf[i] = '\0';
		hq = c->aux;
		hq->addr = strtoul(buf, &b, 0);
		if(*b == '+')
			hq->module = strtoul(b, &b, 0);
		if(*b++ != '.')
			error(Ebadctl);
		hq->fmt = *b++;
		hq->count = strtoul(b, nil, 0);
		break;
	default:
		print("unknown qid in procwrite\n");
		error(Egreg);
	}
	poperror();
	prelease();
	return n;
}

static Bpt*
setbpt(Bpt *bpts, char *path, int pc)
{
	int n;
	Bpt *b;

	n = strlen(path);
	b = mallocz(sizeof *b + n, 0);
	if(b == nil)
		return bpts;
	b->pc = pc;
	memmove(b->path, path, n+1);
	b->file = b->path;
	path = strrchr(b->path, '/');
	if(path != nil)
		b->file = path + 1;
	b->next = bpts;
	return b;
}

static Bpt*
delbpt(Bpt *bpts, char *path, int pc)
{
	Bpt *b, **last;

	last = &bpts;
	for(b = bpts; b != nil; b = b->next){
		if(b->pc == pc && strcmp(b->path, path) == 0) {
			*last = b->next;
			free(b);
			break;
		}
		last = &b->next;
	}
	return bpts;
}

static void
freebpts(Bpt *b)
{
	Bpt *next;

	for(; b != nil; b = next){
		next = b->next;
		free(b);
	}
}

static void
telldbg(Progctl *ctl, char *msg)
{
	kstrcpy(ctl->msg, msg, ERRMAX);
	ctl->debugger = nil;
	wakeup(&ctl->r);
}

static void
dbgstart(Prog *p)
{
	Osenv *o;
	Progctl *ctl;

	o = p->osenv;
	ctl = o->debug;
	if(ctl != nil && ctl->debugger != nil)
		error("prog debugged");
	if(p->state == Pdebug)
		addrun(p);
	o->debug = nil;
	p->xec = xec;
}

static int
xecdone(void *vc)
{
	Progctl *ctl = vc;

	return ctl->debugger == nil;
}

static void
dbgstep(Progctl *vctl, Prog *p, int n)
{
	Osenv * volatile o;
	Progctl * volatile ctl;
	char buf[ERRMAX+20], *msg;

	if(p == currun())
		error("cannot step yourself");

	if(p->state == Pbroken)
		error("prog broken");

	ctl = vctl;
	if(ctl->debugger != nil)
		error("prog already debugged");

	o = p->osenv;
	if(o->debug == nil) {
		o->debug = ctl;
		p->xec = dbgxec;
	}else if(o->debug != ctl)
		error("prog already debugged");

	ctl->step = n;
	if(p->state == Pdebug)
		addrun(p);
	ctl->debugger = up;
	strcpy(buf, "child: ");
	msg = buf+7;
	ctl->msg = msg;

	/*
	 * wait for reply from dbgxec; release is okay because prog is now
	 * debugged, cannot exit.
	 */
	if(waserror()){
		acquire();
		ctl->debugger = nil;
		ctl->msg = nil;
		o->debug = nil;
		p->xec = xec;
		nexterror();
	}
	release();
	sleep(&ctl->r, xecdone, ctl);
	poperror();
	acquire();
	if(msg[0] != '\0')
		error(buf);
}

void
dbgexit(Prog *kid, int broken, char *estr)
{
	int n;
	Osenv *e;
	Progctl *ctl;
	char buf[ERRMAX+20];

	e = kid->osenv;
	ctl = e->debug;
	e->debug = nil;
	kid->xec = xec;

	if(broken)
		n = snprint(buf, sizeof(buf), "broken: %s", estr);
	else
		n = snprint(buf, sizeof(buf), "exited");
	if(ctl->debugger)
		telldbg(ctl, buf);
	qproduce(ctl->q, buf, n);
}

static void
dbgaddrun(Prog *p)
{
	Osenv *o;

	p->state = Pdebug;
	p->addrun = nil;
	o = p->osenv;
	if(o->rend != nil)
		wakeup(o->rend);
	o->rend = nil;
}

static int
bdone(void *vp)
{
	Prog *p = vp;

	return p->addrun == nil;
}

static void
dbgblock(Prog *p)
{
	Osenv *o;
	Progctl *ctl;

	o = p->osenv;
	ctl = o->debug;
	qproduce(ctl->q, progstate[p->state], strlen(progstate[p->state]));
	pushrun(p);
	p->addrun = dbgaddrun;
	o->rend = &up->sleep;

	/*
	 * bdone(p) is safe after release because p is being debugged,
	 * so cannot exit.
	 */
	if(waserror()){
		acquire();
		nexterror();
	}
	release();
	if(o->rend != nil)
		sleep(o->rend, bdone, p);
	poperror();
	acquire();
	if(p->kill != nil)
		error(p->kill);
	ctl = o->debug;
	if(ctl != nil)
		qproduce(ctl->q, "run", 3);
}

void
dbgxec(Prog *p)
{
	Bpt *b;
	Prog *kid;
	Osenv *env;
	Progctl *ctl;
	int op, pc, n;
	char buf[ERRMAX+10];

	env = p->osenv;
	ctl = env->debug;
	ctl->ref++;
	if(waserror()){
		closedbgctl(ctl, p);
		nexterror();
	}

	R = p->reg;
	R.MP = R.M->MP;

	R.IC = p->quanta;
	if((ulong)R.IC > ctl->step)
		R.IC = ctl->step;
	if(ctl->stop)
		R.IC = 0;


	buf[0] = '\0';

	if(R.IC != 0 && R.M->compiled) {
		comvec();
		if(p != currun())
			dbgblock(p);
		goto save;
	}

	while(R.IC != 0) {
		if(0)
			print("step: %lux: %s %4ld %D\n",
				(ulong)p, R.M->m->name, R.PC-R.M->prog, R.PC);

		dec[R.PC->add](OPCALLR);
		op = R.PC->op;
		R.PC++;
		optab[op](OPCALLR);

		/*
		 * check notification about new progs
		 */
		if(op == ISPAWN || op == IMSPAWN) {
			/* pick up the kid from the end of the run queue */
			kid = delruntail(Pdebug);
			n = snprint(buf, sizeof buf, "new %d", kid->pid);
			qproduce(ctl->q, buf, n);
			buf[0] = '\0';
		}
		if(op == ILOAD) {
			n = snprint(buf, sizeof buf, "load %s", string2c(*(String**)R.s));
			qproduce(ctl->q, buf, n);
			buf[0] = '\0';
		}

		/*
		 * check for returns at big steps
		 */
		if(op == IRET)
			R.IC = 1;

		/*
		 * check for blocked progs
		 */
		if(R.IC == 1 && p != currun())
			dbgblock(p);
		if(ctl->stop)
			R.IC = 1;
		R.IC--;

		if(ctl->bpts == nil)
			continue;

		pc = R.PC - R.M->prog;
		for(b = ctl->bpts; b != nil; b = b->next) {
			if(pc == b->pc &&
			  (strcmp(R.M->m->path, b->path) == 0 ||
			   strcmp(R.M->m->path, b->file) == 0)) {
				strcpy(buf, "breakpoint");
				goto save;
			}
		}
	}
save:
	if(ctl->stop)
		strcpy(buf, "stopped");

	p->reg = R;

	if(env->debug == nil) {
		poperror();
		return;
	}

	if(p == currun())
		delrun(Pdebug);

	telldbg(env->debug, buf);
	poperror();
	closedbgctl(env->debug, p);
}

/*
 * emu's Dev has a single init hook; a native kernel's has reset, init
 * and shutdown, so the initializer is positional in a different shape.
 * Getting this wrong is not a subtle bug -- every entry after the
 * mismatch is a function pointer of the wrong type, and the first call
 * through one goes somewhere arbitrary.
 */
Dev progdevtab = {
	'p',
	"prog",

	devreset,
	devinit,
	devshutdown,
	progattach,
	progwalk,
	progstat,
	progopen,
	devcreate,
	progclose,
	progread,
	devbread,
	progwrite,
	devbwrite,
	devremove,
	progwstat,
};
