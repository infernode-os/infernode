/*
 * Imported from upstream Inferno os/port/dis.c.
 *
 * DIVERGENCE FROM UPSTREAM: Chan, Pgrp, Fgrp, Egrp and friends embed
 * named Lock/Ref members rather than anonymous ones. Which member each
 * call site wants was taken from the TARGET parameter type reported by
 * the compiler, since several of these structs embed both.
 * See os/bcm2837/README.md.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include <isa.h>
#include <interp.h>
#include <kernel.h>
#include "raise.h"

	void	vmachine(void*);

/*
 * A VM's scheduler (#944): the interpreter token, which procs queue for
 * in acquire(), its run queue and its Progs. isched is the one of the
 * VM the current process belongs to -- not the core's, because acquire()
 * is called by a process that does not hold any yet.
 */
typedef struct Isched Isched;
struct Isched
{
	Lock	l;
	Prog*	runhd;
	Prog*	runtl;
	Prog*	head;
	Prog*	tail;
	Rendez	irend;
	int	idle;
	int	nyield;
	int	creating;
	Proc*	vmq;		/* queue of procs wanting vm */
	Proc*	vmqt;
	Proc*	idlevmq;	/* queue of procs wanting work */
	Atidle*	idletasks;
};
static	Isched	sched0;		/* vm0's */
#define	VMSCHED(v)	((Isched*)(v)->vsched)
#define	isched	(*VMSCHED(up->vm))

int	bflag = 1;	/* JIT array bounds checks; emu -B clears it */
int	cflag;
uvlong	gcbusy;
uvlong	gcidle;
uvlong	gcidlepass;
uvlong	gcpartial;
int keepbroken = 1;
static Prog*	proghash[64];
/*
 * pids are unique across every VM, and the pid hash is global: kill,
 * /prog and wait look a Prog up by pid from anywhere. So they have a
 * lock of their own; each VM's lists are under its interpreter (#944).
 */
static Lock	pidlk;

/*
 * Every Prog pointer stored into the run queue must point at RAM, and
 * RAM ends well below 4GB on this board. A value with the high word
 * set is corruption in flight -- catch it at the store, with the
 * storer named, instead of as a data abort one dequeue later. The
 * checks cost a compare per queue operation, and they helped convict
 * the usbdwc bounce-buffer use-after-free; they stay.
 */
static void
chkprog(Prog *p, char *who)
{
	if(p != nil && ((uvlong)(uintptr)p >> 32) != 0)
		panic("runq poison: %s stores %#p cpu%d pc %#lux",
			who, p, m->machno, getcallerpc(&p));
}

static Progs*	delgrp(Prog*);
static void	addgrp(Prog*, Prog*);
void	printgrp(Prog*, char*);

static Prog**
pidlook(int pid)
{
	ulong h;
	Prog **l;

	h = (ulong)pid % nelem(proghash);
	for(l = &proghash[h]; *l != nil && (*l)->pid != pid; l = &(*l)->pidlink)
		;
	return l;
}

int
tready(void *a)
{
	USED(a);
	return isched.runhd != nil || isched.vmq != nil;
}

Prog*
progpid(int pid)
{
	Prog *p;

	lock(&pidlk);
	p = *pidlook(pid);
	unlock(&pidlk);
	return p;
}

/*
 * The VMs (#944). vm0 is the boot VM, the desktop's; the others are
 * made when something is first run in them (/dev/vm, devvm.c). A VM
 * is never destroyed.
 */
static Vm*	vms[MAXVM] = { &vm0 };
static int	nvms = 1;
static Lock	vmlk;

int
vmcount(void)
{
	return nvms;
}

Vm*
vmn(int n)
{
	if(n < 0 || n >= MAXVM)
		return nil;
	return vms[n];
}

/*
 * The n'th Prog of all of them, in VM order. Under pidlk, which every
 * VM's list changes take, so the walk is safe from another VM's
 * newprog and delprog; the Prog itself is only safe to touch under its
 * own VM (devprog's pacquire).
 */
static Prog*
prognlocked(int n)
{
	int i;
	Prog *p;

	for(i = 0; i < nvms; i++)
		if(vms[i] != nil)
			for(p = VMSCHED(vms[i])->head; p != nil; p = p->next)
				if(n-- == 0)
					return p;
	return nil;
}

Prog*
progn(int n)
{
	Prog *p;

	lock(&pidlk);
	p = prognlocked(n);
	unlock(&pidlk);
	return p;
}

/* the pid of the n'th Prog, or -1: what can be kept after the lock */
int
progpidn(int n)
{
	Prog *p;
	int pid;

	lock(&pidlk);
	p = prognlocked(n);
	pid = p != nil ? p->pid : -1;
	unlock(&pidlk);
	return pid;
}

/* the VM a pid's Prog runs in, or nil if there is no such Prog */
Vm*
pidvm(int pid)
{
	Prog *p;
	Vm *v;

	lock(&pidlk);
	p = *pidlook(pid);
	v = p != nil ? p->vm : nil;
	unlock(&pidlk);
	return v;
}

/* how many Progs one VM has */
int
vmprogs(Vm *v)
{
	int n;
	Prog *p;

	n = 0;
	lock(&pidlk);
	for(p = VMSCHED(v)->head; p != nil; p = p->next)
		n++;
	unlock(&pidlk);
	return n;
}

int
nprog(void)
{
	int i, n;
	Prog *p;

	n = 0;
	lock(&pidlk);
	for(i = 0; i < nvms; i++)
		if(vms[i] != nil)
			for(p = VMSCHED(vms[i])->head; p != nil; p = p->next)
				n++;
	unlock(&pidlk);
	return n;
}

static void
accountant(void)
{
	Prog *p;

	int i;

	/* on the clock, in whatever process it interrupted: every VM's */
	for(i = 0; i < nvms; i++){
		if(vms[i] == nil)
			continue;
		p = VMSCHED(vms[i])->runhd;
		if(p != nil)
			p->ticks++;
	}
}

/*
 * How much collection to do before going to sleep, in rungc() calls.
 *
 * WHY THIS IS A COUNT OF QUANTA AND NOT, AS IT WAS, A COUNT OF EPOCHS.
 * "Idle" here does not mean the machine has nothing to do. It means no
 * Limbo process is ready THIS INSTANT, which on an I/O-bound workload
 * is simply the gap between one packet and the next -- so this runs to
 * completion before the sleep that waits for the packet, and the
 * network pays it on every single round trip.
 *
 * That would be tolerable if the work were bounded, and an epoch is
 * not. rungc() ends an epoch only when a full traversal finds nothing
 * left to propagate (nprop == 0); until then it traverses the heap
 * again. So "three epochs" is not three passes over the heap, it is
 * however many passes the mark phase needs to converge, three times
 * over, with the interpreter lock held throughout and the Ethernet
 * driver -- itself a Limbo process -- unable to run until it ends.
 *
 * Measured on the board, 1MB TCP round trip, bytes verified each time:
 *
 *	3 epochs (as it was)	 28 KB/s
 *	1 epoch			 79 KB/s
 *	none at all		324 KB/s
 *
 * That is not a curve with a knee to sit on; it is the cost of
 * finishing a traversal at all. A quantum, by contrast, is bounded by
 * construction -- rungc() visits at most MaxQuanta blocks and returns
 * -- so a cap on quanta is a real cap on the time before the sleep.
 *
 * The point of collecting at idle is preserved: spare moments still do
 * collection, and a machine with genuinely nothing to do still makes
 * progress every time round. What is given up is the insistence on
 * FINISHING, which is what nobody was waiting for.
 */
#ifndef Idlequanta
#define Idlequanta 8
#endif

/*
 * How many Prog quanta to run before handing the interpreter to a
 * process waiting in acquire().
 *
 * A Limbo process that makes a blocking system call drops the
 * interpreter and must queue on isched.vmq to get it back. Until it
 * does, it has finished its I/O and is doing nothing -- so on an
 * I/O-bound workload this looks like an obvious thing to shorten, and
 * it was tried. It is not, and the knob is left here at the value it
 * has always had so the next person does not have to spend the
 * afternoon finding out.
 *
 * Measured on the board, 1MB TCP round trip and one-way both ways:
 *
 *	2 (as it is)	round trip 111-411 KB/s, out 1384, in 585
 *	1		round trip 159-453 KB/s, out 1414, in 575
 *	0 (yield always) round trip 343-447 KB/s, out unchanged
 *
 * One-way throughput does not move at all, which is the number that
 * says whether the machine goes faster. Only the round trip appears to
 * improve, and it is far too noisy across three samples to carry that
 * conclusion on its own -- the ranges overlap.
 *
 * Against that, both 0 and 1 cost a harness failure, the same one each
 * time: /lib/sh/profile has not finished "load std" by the time the
 * shell takes input. The interpreter is fine -- "load std" by hand
 * then works -- so it is boot ORDERING that changed, and a shell that
 * becomes interactive before its profile is ready is a real
 * regression, cheaply bought.
 *
 * The time this looked like it would recover is not here anyway. See
 * the note on Idlequanta above for where it actually was, and the
 * roadmap for where the rest of it is: the 9P server path that every
 * frame crosses, which no scheduler tuning can shorten.
 */
#ifndef Vmcycles
#define Vmcycles 2
#endif

static void
execatidle(void)
{
	int i;

	if(tready(nil))
		return;

	gcidle++;
	up->type = IdleGC;
	up->iprog = nil;
	addrun(up->prog);

	for(i = 0; i < Idlequanta && gcruns(); i++) {
		if(isched.vmq != nil || isched.runhd != isched.runtl) {
			gcpartial++;
			break;
		}
		rungc(isched.head);
		gcidlepass++;
		if(((ulong)gcidlepass&0xFF) == 0)
			sched();
	}

	up->type = Interp;
	delrunq(up->prog);
}

Prog*
newprog(Prog *p, Modlink *m)
{
	Heap *h;
	Prog *n, **ph;
	Osenv *on, *op;
	static int pidnum;

	if(p != nil){
		if(p->group != nil)
			p->flags |= p->group->flags & Pkilled;
		if(p->kill != nil)
			error(p->kill);
		if(p->flags & Pkilled)
			error("");
	}
	n = malloc(sizeof(Prog)+sizeof(Osenv));
	if(n == 0){
		if(p == nil)
			panic("no memory");
		else
			error(exNomem);
	}

	n->vm = up->vm;
	n->group = nil;

	lock(&pidlk);
	n->pid = ++pidnum;
	if(n->pid <= 0)
		panic("no pids");
	if(isched.tail != nil) {
		n->prev = isched.tail;
		isched.tail->next = n;
	}
	else {
		isched.head = n;
		n->prev = nil;
	}
	isched.tail = n;
	ph = pidlook(n->pid);
	if(*ph != nil)
		panic("dup pid");
	n->pidlink = nil;
	*ph = n;
	unlock(&pidlk);

	n->osenv = (Osenv*)((uchar*)n + sizeof(Prog));
	n->xec = xec;
	n->quanta = PQUANTA;
	n->flags = 0;
	n->exval = H;

	h = D2H(m);
	h->ref++;
	Setmark(h);
	n->reg.M = m;
	n->reg.MP = m->MP;
	if(m->MP != H)
		Setmark(D2H(m->MP));
	addrun(n);

	if(p == nil){
		newgrp(n);
		return n;
	}

	addgrp(n, p);
	n->flags = p->flags;
	if(p->flags & Prestrict)
		n->flags |= Prestricted;
	memmove(n->osenv, p->osenv, sizeof(Osenv));
	op = p->osenv;
	on = n->osenv;
	on->waitq = op->childq;
	on->childq = nil;
	on->debug = nil;
	incref(&on->pgrp->r);
	incref(&on->fgrp->r);
	if(on->egrp != nil)
		incref(&on->egrp->r);
	if(on->sigs != nil)
		incref(&on->sigs->r);
	on->user = nil;
	kstrdup(&on->user, op->user);
	on->errstr = on->errbuf0;
	on->syserrstr = on->errbuf1;

	return n;
}

void
delprog(Prog *p, char *msg)
{
	Osenv *o;
	Prog **ph;

	int n0, n1, n2, n3;

	n0 = up->nerrlab;
	tellsomeone(p, msg);	/* call before being removed from prog list */
	n1 = up->nerrlab;

	o = p->osenv;
	release();
	closepgrp(o->pgrp);
	n2 = up->nerrlab;
	closefgrp(o->fgrp);
	n3 = up->nerrlab;
	closeegrp(o->egrp);
	closesigs(o->sigs);
	acquire();
	/*
	 * The one place a kproc runs kernel code for a Prog that is
	 * gone, released, with closes that block on other Progs and a
	 * kill that can land as Eintr in the middle. Every error-stack
	 * imbalance the board has caught came with a Prog exiting in
	 * that quantum, so: which of these left the stack off?
	 */
	if(up->nerrlab != n0)
		print("delprog %d \"%s\": error stack %d -> tellsomeone %d -> closepgrp %d -> closefgrp %d -> %d\n",
			p->pid, msg, n0, n1, n2, n3, up->nerrlab);

	delgrp(p);

	lock(&pidlk);
	if(p->prev)
		p->prev->next = p->next;
	else
		isched.head = p->next;

	if(p->next)
		p->next->prev = p->prev;
	else
		isched.tail = p->prev;

	ph = pidlook(p->pid);
	if(*ph == nil)
		panic("lost pid");
	*ph = p->pidlink;
	unlock(&pidlk);

	if(p == isched.runhd) {
		isched.runhd = p->link;
		if(p->link == nil)
			isched.runtl = nil;
	}
	p->state = 0xdeadbeef;
	free(o->user);
	free(p->killstr);
	free(p->exstr);
	free(p);
}

void
renameproguser(char *old, char *new)
{
	Prog *p;
	Osenv *o;

	acquire();
	for(p = isched.head; p; p = p->next){
		o = p->osenv;
		if(o->user != nil && strcmp(o->user, old) == 0)
			kstrdup(&o->user, new);
	}
	release();
}

void
tellsomeone(Prog *p, char *buf)
{
	Osenv *o;

	if(waserror())
		return;
	o = p->osenv;
	if(o->childq != nil)
		qproduce(o->childq, buf, strlen(buf));
	if(o->waitq != nil)
		qproduce(o->waitq, buf, strlen(buf));
	poperror();
}

static void
swiprog(Prog *p)
{
	Proc *q, *eq;

	q = proctab(0);
	for(eq = q+conf.nproc; q < eq; q++) {
		if(q->iprog == p) {
			swiproc(q, 1);
			return;
		}
	}
	/*print("didn't find\n");*/
}

static Prog*
grpleader(Prog *p)
{
	Progs *g;
	Prog *l;

	g = p->group;
	if(g != nil && (l = g->head) != nil && l->pid == g->id)
		return l;
	return nil;
}

int
exprog(Prog *p, char *exc)
{
	switch(p->state) {
	case Palt:
		altdone(p->reg.s, p, nil, -1);
		break;
	case Psend:
		cqdelp(&p->chan->send, p);
		break;
	case Precv:
		cqdelp(&p->chan->recv, p);
		break;
	case Pready:
		break;
	case Prelease:
		swiprog(p);
		break;
	case Pexiting:
	case Pbroken:
	case Pdebug:
		return 0;
	default:
		panic("exprog - bad state 0x%x\n", p->state);
	}
	if(p->state != Pready && p->state != Prelease)
		addrun(p);
	if(p->kill == nil){
		if(p->killstr == nil){
			p->killstr = malloc(ERRMAX);
			if(p->killstr == nil){
				p->kill = Enomem;
				return 1;
			}
		}
		kstrcpy(p->killstr, exc, ERRMAX);
		p->kill = p->killstr;
	}
	return 1;
}

static void
propex(Prog *p, char *estr)
{
	Prog *f, *nf, *pgl;

	if(!(p->flags & (Ppropagate|Pnotifyleader)) || p->group == nil)
		return;
	if(*estr == 0){
		if((p->flags & Pkilled) == 0)
			return;
		estr = "killed";
	}
	pgl = grpleader(p);
	if(pgl == nil)
		pgl = p;
	if(!(pgl->flags & (Ppropagate|Pnotifyleader)))
		return;	/* exceptions are local; don't propagate */
	for(f = p->group->head; f != nil; f = nf){
		nf = f->grpnext;
		if(f != p && f != pgl){
			if(pgl->flags & Ppropagate)
				exprog(f, estr);
			else{
				f->flags &= ~(Ppropagate|Pnotifyleader);	/* prevent recursion */
				killprog(f, "killed");
			}
		}
	}
	if(p != pgl)
		exprog(pgl, estr);
}

int
killprog(Prog *p, char *cause)
{
	Osenv *env;
	char msg[ERRMAX+2*KNAMELEN];

	if(p == isched.runhd) {
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		return 0;
	}

	switch(p->state) {
	case Palt:
		altdone(p->reg.s, p, nil, -1);
		break;
	case Psend:
		cqdelp(&p->chan->send, p);
		break;
	case Precv:
		cqdelp(&p->chan->recv, p);
		break;
	case Pready:
		delrunq(p);
		break;
	case Prelease:
		p->kill = "";
		p->flags |= Pkilled;
		p->state = Pexiting;
		swiprog(p);
		/* No break */
	case Pexiting:
		return 0;
	case Pbroken:
	case Pdebug:
		break;
	default:
		panic("killprog - bad state 0x%x\n", p->state);
	}

	if(p->addrun != nil) {
		p->kill = "";
		p->flags |= Pkilled;
		p->addrun(p);
		p->addrun = nil;
		return 0;
	}

	env = p->osenv;
	if(env->debug != nil) {
		p->state = Pbroken;
		dbgexit(p, 0, cause);
		return 0;
	}

	propex(p, "killed");

	snprint(msg, sizeof(msg), "%d \"%s\":%s", p->pid, p->reg.M->m->name, cause);

	p->state = Pexiting;
	gclock();
	destroystack(&p->reg);
	delprog(p, msg);
	gcunlock();

	return 1;
}

void
newgrp(Prog *p)
{
	Progs *pg, *g;

	if(p->group != nil && p->group->id == p->pid)
		return;
	g = malloc(sizeof(*g));
	if(g == nil)
		error(Enomem);
	p->flags &= ~(Ppropagate|Pnotifyleader);
	g->id = p->pid;
	g->flags = 0;
	g->child = nil;
	pg = delgrp(p);
	g->head = g->tail = p;
	p->group = g;
	if(pg != nil){
		g->sib = pg->child;
		pg->child = g;
	}
	g->parent = pg;
}

static void
addgrp(Prog *n, Prog *p)
{
	Progs *g;

	n->group = p->group;
	if((g = n->group) != nil){
		n->grpnext = nil;
		if(g->head != nil){
			n->grpprev = g->tail;
			g->tail->grpnext = n;
		}else{
			n->grpprev = nil;
			g->head = n;
		}
		g->tail = n;
	}
}

static Progs*
delgrp(Prog *p)
{
	Progs *g, *pg, *cg, **l;

	g = p->group;
	if(g == nil)
		return nil;
	if(p->grpprev)
		p->grpprev->grpnext = p->grpnext;
	else
		g->head = p->grpnext;
	if(p->grpnext)
		p->grpnext->grpprev = p->grpprev;
	else
		g->tail = p->grpprev;
	p->grpprev = p->grpnext = nil;
	p->group = nil;

	if(g->head == nil){
		/* move up, giving subgroups of groups with no Progs to their parents */
		do{
			if((pg = g->parent) != nil){
				pg = g->parent;
				for(l = &pg->child; *l != nil && *l != g; l = &(*l)->sib)
					;
				*l = g->sib;
			}
			/* put subgroups in new parent group */
			while((cg = g->child) != nil){
				g->child = cg->sib;
				cg->parent = pg;
				if(pg != nil){
					cg->sib = pg->child;
					pg->child = cg;
				}
			}
			free(g);
		}while((g = pg) != nil && g->head == nil);
	}
	return g;
}

void
printgrp(Prog *p, char *v)
{
	Progs *g;
	Prog *q;

	g = p->group;
	print("%s pid %d grp %d pgrp %d: [pid", v, p->pid, g->id, g->parent!=nil?g->parent->id:0);
	for(q = g->head; q != nil; q = q->grpnext)
		print(" %d", q->pid);
	print(" subgrp");
	for(g = g->child; g != nil; g = g->sib)
		print(" %d", g->id);
	print("]\n");
}

int
killgrp(Prog *p, char *msg)
{
	int i, npid, *pids;
	Prog *f;
	Progs *g;

	/* interpreter has been acquired */
	g = p->group;
	if(g == nil || g->head == nil)
		return 0;
	while(g->flags & Pkilled){
		release();
		acquire();
	}
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		if(f->group != g)
			panic("killgrp");
		else
			npid++;
	/* use pids not Prog* because state can change during killprog (eg, in delprog) */
	pids = malloc(npid*sizeof(int));
	if(pids == nil)
		error(Enomem);
	npid = 0;
	for(f = g->head; f != nil; f = f->grpnext)
		pids[npid++] = f->pid;
	g->flags |= Pkilled;
	if(waserror()) {
		g->flags &= ~Pkilled;
		free(pids);
		nexterror();
	}
	for(i = 0; i < npid; i++) {
		f = progpid(pids[i]);
		if(f != nil && f != currun())
			killprog(f, msg);
	}
	poperror();
	g->flags &= ~Pkilled;
	free(pids);
	return 1;
}

char	changup[] = "channel hangup";

void
killcomm(Progq **q)
{
	Prog *p;
	Progq *f;

	for (f = *q; f != nil; f = *q) {
		*q = f->next;
		p = f->prog;
		free(f);
		if(p == nil)
			return;
		p->ptr = nil;
		switch(p->state) {
		case Prelease:
			swiprog(p);
			break;
		case Psend:
		case Precv:
			p->kill = changup;
			addrun(p);
			break;
		case Palt:
			altgone(p);
			break;
		}
	}
}

void
addprog(Proc *p)
{
	Prog *n;

	if((n = p->prog) == nil) {
		n = malloc(sizeof(Prog));
		if(n == nil)
			panic("no memory");
		p->prog = n;
	} else
		memset(n, 0, sizeof(Prog));
	n->osenv = p->env;
}

static void
cwakeme(Prog *p)
{
	Osenv *o;

	p->addrun = nil;
	o = p->osenv;
	wakeup(o->rend);
}

static int
cdone(void *vp)
{
	Prog *p = vp;

	return p->addrun == nil || p->kill != nil;
}

void
cblock(Prog *p)
{
	Osenv *o;

	p->addrun = cwakeme;
	o = p->osenv;
	o->rend = &up->sleep;
	release();

	/*
	 * To allow cdone(p) safely after release,
	 * p must be currun before the release.
	 * Exits in the error case with the vm acquired.
	 */
	if(waserror()) {
		acquire();
		p->addrun = nil;
		nexterror();
	}
	sleep(o->rend, cdone, p);
	if (p->kill != nil)
		error(Eintr);
	poperror();
	acquire();
}

void
addrun(Prog *p)
{
	if(p->addrun != 0) {
		p->addrun(p);
		return;
	}
	if(p->state == Pready && p != (Prog *)up->prog)
		panic("addrun of ready prog %8.8p by %8.8lux\n", p, getcallerpc(&p));
	p->state = Pready;
	p->link = nil;
	/* #635: where does a compiled Prog's saved PC go bad? */
	/*
	 * R.M is nil, not H, for a Prog whose module is not linked yet
	 * (disinit's first). On arm64 page 0 is mapped and the read of
	 * nil->compiled quietly returned junk; with no memory there (RISC-V,
	 * no paging) it is a load access fault in the boot's first addrun.
	 */
	if(p->reg.M != nil && p->reg.M != H && p->reg.M->compiled && ((uintptr)p->reg.PC & 3))
		print("BUG: addrun: prog %d %s R.PC=%p (prog %p) from %#p\n",
			p->pid, p->reg.M->m? p->reg.M->m->name : "?", p->reg.PC,
			p->reg.M->m? (void*)p->reg.M->m->prog : nil, getcallerpc(&p));
	chkprog(p, "addrun");
	chkprog(isched.runtl, "addrun.tl");
	if(isched.runhd == nil)
		isched.runhd = p;
	else
		isched.runtl->link = p;

	isched.runtl = p;
}

Prog*
delrun(int state)
{
	Prog *p;

	p = isched.runhd;
	chkprog(p, "delrun");
	chkprog(p->link, "delrun.link");
	p->state = state;
	isched.runhd = p->link;
	if(p->link == nil)
		isched.runtl = nil;

	return p;
}

void
delrunq(Prog *p)
{
	Prog *prev, *f;

	prev = nil;
	for(f = isched.runhd; f; f = f->link) {
		chkprog(f, "delrunq.scan");
		if(f == p)
			break;
		prev = f;
	}
	if(f == nil)
		return;
	if(prev == nil)
		isched.runhd = p->link;
	else
		prev->link = p->link;
	if(p == isched.runtl)
		isched.runtl = prev;
}

Prog*
delruntail(int state)
{
	Prog *p;

	p = isched.runtl;
	delrunq(isched.runtl);
	p->state = state;
	return p;
}

Prog*
currun(void)
{
	return isched.runhd;
}

Prog*
schedmod(Module *m)
{
	Heap *h;
	Type *t;
	Prog *p;
	Modlink *ml;
	Frame f, *fp;

	ml = mklinkmod(m, 0);

	if(m->origmp != H && m->ntype > 0) {
		t = m->type[0];
		h = nheap(t->size);
		h->t = t;
		t->ref++;
		ml->MP = H2D(uchar*, h);
		newmp(ml->MP, m->origmp, t);
	}

	p = newprog(nil, ml);
	h = D2H(ml);
	h->ref--;
	p->reg.PC = m->entry;
	fp = &f;
	R.s = &fp;
	f.t = m->entryt;
	newstack(p);
	initmem(m->entryt, p->reg.FP);

	return p;
}

/*
 * VM n, made if it is not there yet (#944): a scheduler whose
 * interpreter is free, a heap pool of its own, a collector at the
 * start of its first epoch. Its builtin modules are registered by the
 * first vmrun, under its interpreter. nil if n is out of range or the
 * pools are all taken.
 */
Vm*
vmget(int n)
{
	static char names[MAXVM][8];
	Vm *v;
	Isched *s;

	if(n < 0 || n >= MAXVM)
		return nil;
	lock(&vmlk);
	v = vms[n];
	if(v == nil){
		v = mallocz(sizeof(Vm), 1);
		s = mallocz(sizeof(Isched), 1);
		snprint(names[n], sizeof names[n], "heap%d", n);
		if(v == nil || s == nil || (v->vheap = heappoolnew(names[n])) == nil){
			unlock(&vmlk);
			free(v);
			free(s);
			return nil;
		}
		v->id = n;
		v->vgccolor = 3;	/* as vm0's (xec.c) */
		v->marker = 1;
		v->sweeper = 2;
		v->quanta = 50;
		v->gct = 1;
		s->idle = 1;		/* the interpreter is free: the first acquire takes it */
		v->vsched = s;
		vms[n] = v;
		if(n >= nvms)
			nvms = n+1;
	}
	unlock(&vmlk);
	return v;
}

/*
 * Run a module in VM n: init(nil, argv), with the caller's namespace,
 * environment and file descriptors as a spawn would share them, and
 * its own heap there. Returns the new pid. The caller is in a system
 * call, holding no interpreter; it takes VM n's for the length of the
 * load, as a crossing does (#944), and the release that ends it starts
 * the VM's first interpreter process if it has none.
 *
 * init's parameters are where the Limbo compiler puts a function's
 * first two: MaxTemp, (NREG+3) words into the frame (limbo/limbo.h).
 * The frame type is checked to say both are pointers, so a module
 * whose init is not init(ctxt, argv) is refused, not mis-called.
 */
int
vmrun(int n, int argc, char **argv)
{
	Vm *v, *home;
	Module *root;
	Prog *p;
	Osenv *o;
	Type *t;
	List *l;
	String *s;
	uchar *fp;
	int i, pid, w;

	if(argc < 1)
		error(Ebadarg);
	v = vmget(n);
	if(v == nil)
		error("no such VM");
	home = up->vm;
	up->vm = v;
	acquire();
	if(waserror()){
		release();
		up->vm = home;
		nexterror();
	}
	if(!v->ready){
		vmbuiltins();
		v->ready = 1;
	}
	/*
	 * As OP(load) does it, not as load() does: the interpreter is let
	 * go while the file is read, because the file may be served by a
	 * Dis program -- /dis on the card is dossrv's, in vm0 -- which must
	 * run to answer. Held, that is a deadlock.
	 */
	root = readmod(argv[0], lookmod(argv[0]), 1);
	if(root == nil){
		kgerrstr(up->genbuf, sizeof up->genbuf);
		error(up->genbuf);
	}
	t = root->entryt;
	w = NREG+3;
	if(t == nil || t->np <= (w+1)/8 || (t->map[w/8] & (0x80>>(w%8))) == 0 || (t->map[(w+1)/8] & (0x80>>((w+1)%8))) == 0)
		error("not a command: init is not init(ctxt, argv)");
	p = schedmod(root);

	l = (List*)H;
	for(i = argc-1; i >= 0; i--){
		s = c2string(argv[i], strlen(argv[i]));
		l = cons(IBY2WD, &l);
		l->t = &Tptr;
		Tptr.ref++;
		*(String**)l->data = s;
	}
	fp = p->reg.FP;
	*(WORD**)(fp + w*IBY2WD) = H;		/* ctxt: nil */
	*(List**)(fp + (w+1)*IBY2WD) = l;	/* argv */

	memmove(p->osenv, up->env, sizeof(Osenv));
	o = p->osenv;
	incref(&o->pgrp->r);
	incref(&o->fgrp->r);
	if(o->egrp != nil)
		incref(&o->egrp->r);
	if(o->sigs != nil)
		incref(&o->sigs->r);
	o->user = nil;
	kstrdup(&o->user, up->env->user);
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;
	o->waitq = nil;
	o->childq = nil;
	o->debug = nil;
	pid = p->pid;

	poperror();
	release();
	up->vm = home;
	return pid;
}

/*
 * Getting the interpreter back was timed here for a while, on the
 * theory that it was where a USB bulk write's unaccounted-for
 * milliseconds went. It is not: 120000 waits averaged 47us. The
 * timing is gone rather than left in because this runs on every
 * system call every Limbo program makes.
 */
void
acquire(void)
{
	int empty;
	Prog *p;

	lock(&isched.l);
	if(isched.idle) {
		isched.idle = 0;
		unlock(&isched.l);
	}
	else {
		up->qnext = nil;
		if(isched.vmq != nil){
			empty = 0;
			isched.vmqt->qnext = up;
		}else{
			isched.vmq = up;
			empty = 1;
		}
		isched.vmqt = up;

		SETSTATE(up, Queueing);
		up->pc = getcallerpc(&empty);
		unlock(&isched.l);
		if(empty)
			wakeup(&isched.irend);
		sched();
	}

#ifdef VMREGPERMACH
	/*
	 * This core now runs this process's VM: R must be its registers
	 * before irestore loads them (interp.h). sched() does the same on a
	 * switch; this is the path that takes a free interpreter without one.
	 */
	m->vmreg = up->vm;
#endif
	if(up->type == Interp) {
		p = up->iprog;
		up->iprog = nil;
		irestore(p);
	}
	else
		p = up->prog;

	p->state = Pready;
	chkprog(p, "irestore.push");
	p->link = isched.runhd;
	isched.runhd = p;
	if(p->link == nil)
		isched.runtl = p;
}

void
release(void)
{
	Proc *p, **pq;
	int f;

	if(up->type == Interp){
		if(up->iprog != nil)
			panic("Double release (Interp)?");
		up->iprog = isave();
	}else{
		if(((Prog *)up->prog)->state != Pready) panic("double release (GC)?");
		delrun(Prelease);
	}

	lock(&isched.l);
	if(*(pq = &isched.vmq) == nil && *(pq = &isched.idlevmq) == nil) {
		isched.idle = 1;
		f = isched.creating;
		isched.creating = 1;
		unlock(&isched.l);
		if(f == 0)
			kproc("dis", vmachine, nil, 0);
		return;
	}
	p = *pq;
	*pq = p->qnext;
	unlock(&isched.l);

	ready(p);
}

void
iyield(void)
{
	Proc *p;

	lock(&isched.l);
	p = isched.vmq;
	if(p == nil) {
		unlock(&isched.l);
		return;
	}
	isched.nyield++;
	isched.vmq = p->qnext;

	if(up->iprog != nil)
		panic("iyield but iprog, type %d", up->type);
	if(up->type != Interp){
		static int once;
		if(!once++)
			print("tell charles: #%p->type==%d\n", up, up->type);
	}
	up->qnext = isched.idlevmq;
	isched.idlevmq = up;

	SETSTATE(up, Queueing);
	up->pc = getcallerpc(&p);
	unlock(&isched.l);
	ready(p);
	sched();
}

void
startup(void)
{
	int x;

	up->type = Interp;
	up->iprog = nil;

	lock(&isched.l);
	isched.creating = 0;
	if(isched.idle) {
		isched.idle = 0;
		unlock(&isched.l);
		return;
	}
	up->qnext = isched.idlevmq;
	isched.idlevmq = up;
	SETSTATE(up, Queueing);
	up->pc = getcallerpc(&x);
	unlock(&isched.l);
	sched();
}

void
progexit(void)
{
	Prog *r;
	Module *m;
	int broken, n0;
	char *estr, msg[ERRMAX+2*KNAMELEN];

	n0 = up->nerrlab;
	estr = up->env->errstr;
	broken = 0;
	if(estr[0] != '\0' && strcmp(estr, Eintr) != 0 && strncmp(estr, "fail:", 5) != 0)
		broken = 1;

	r = up->iprog;
	if(r != nil)
		acquire();
	else
		r = currun();

	if(*estr == '\0' && r->flags & Pkilled)
		estr = "killed";

	m = R.M->m;
	if(broken)
		print("[%s] Broken: \"%s\"\n", m->name, estr);

	snprint(msg, sizeof(msg), "%d \"%s\":%s", r->pid, m->name, estr);

	if(up->env->debug != nil) {
		dbgexit(r, broken, estr);
		broken = 1;
		/* must force it to break if in debug */
	}else if(broken && (!keepbroken || strncmp(estr, "out of memory", 13)==0 || memusehigh()))
		broken = 0;	/* don't want them or short of memory */

	if(broken){
		tellsomeone(r, msg);
		r = isave();
		r->state = Pbroken;
		if(up->nerrlab != n0)
			print("progexit (broken): error stack %d -> %d\n", n0, up->nerrlab);
		return;
	}

	gclock();
	destroystack(&R);
	delprog(r, msg);
	gcunlock();
	if(up->nerrlab != n0)
		print("progexit: error stack %d -> %d\n", n0, up->nerrlab);
}

void
disfault(void *reg, char *msg)
{
	Prog *p;

	USED(reg);

	if(strncmp(msg, Eintr, 6) == 0 || up == nil) {
		print("EMU: faults: %s\n", msg);
		panic("disfault");
	}
	if(up->type != Interp) {
		print("SYS: process %s faults: %s\n", up->text, msg);
		panic("disfault");
	}

	if(up->iprog != nil)
		acquire();

	p = currun();
	if(p == nil)
		panic("Interp faults with no dis prog");

	/* cause an exception in the dis prog. */
	error(msg);
}

void
vmachine(void*)
{
	Prog *r;
	Osenv *o;
	int cycles, nerr;
	static int gccounter;

	startup();

    for(;;){
	while(waserror()) {
		if(up->type != Interp)
			panic("vmachine: non-interp kproc");

		/*
		 * An error raised while handling an error must not unwind
		 * past this process.
		 *
		 * The label this loop's waserror() pushed was consumed by
		 * the longjmp that got us here, and it is not pushed again
		 * until the loop condition is re-evaluated at the bottom.
		 * For the length of this handler the only label left is the
		 * catch-all in the kproc trampoline, so anything below that
		 * calls error() -- acquire(), handler(), propex(),
		 * progexit() -- unwinds straight out of the kproc.
		 *
		 * That kills the machine, not just the process. A dis kproc
		 * dying here dies holding the interpreter: isched.idle is
		 * never set, the Progs queued on isched.runhd are never
		 * picked up again, and every other dis kproc stays parked
		 * in idlevmq waiting for a wakeup with no owner left to
		 * send it. Userspace stops dead while the kernel carries on
		 * -- still answering ping, still holding the last frame on
		 * the display. A soak run watched exactly that happen after
		 * a single anonymous "error() underflow", and the machine
		 * had to be power-cycled.
		 *
		 * An empty error string reaches here easily, which is how
		 * this path gets exercised at all: handler() returns 0 for
		 * one without looking at anything, so propex() and
		 * progexit() run on a Prog whose state nobody has
		 * established.
		 *
		 * Catching it costs the Prog whose error was being handled
		 * and keeps the interpreter.
		 */
		if(waserror()){
			print("vmachine: error while handling an error: %s\n",
				up->env != nil && up->env->errstr != nil ?
					up->env->errstr : "");
			up->env = &up->defenv;
			continue;
		}
		if(up->iprog != nil)
			acquire();
		if(handler(up->env->errstr) == 0) {
			propex(currun(), up->env->errstr);
			progexit();
		}
		poperror();
		up->env = &up->defenv;
	}

	/*
	 * The error stack as it should be for the whole of the loop
	 * below: the trampoline's label under this function's. A Prog's
	 * quantum is a syscall path or a hundred, and one with a
	 * poperror() too many -- or a handler that pops the label the
	 * longjmp to it already consumed -- leaves the count one short,
	 * with nothing said. The NEXT error() raised in this kproc then
	 * unwinds past this function's label to the trampoline's, and
	 * that is a dead machine: the interpreter's owner exits, and
	 * userspace stops while the kernel pings. The board did exactly
	 * this four times in a day under Bluetooth load, and the only
	 * line it left was the trampoline naming "dis".
	 *
	 * So after every quantum the count is compared with what it
	 * was, and a difference is printed -- naming the Prog and the
	 * module that just ran, which is where the unbalanced pop is --
	 * and repaired, so that the label stays where the next error()
	 * expects it. This does not fix the pop; it makes the pop a line
	 * on the console that says whose, instead of a power cycle.
	 */
	nerr = up->nerrlab;

	cycles = 0;
	for(;;) {
		int pid;
		char *modname;

		if(tready(nil) == 0) {
			execatidle();
			sleep(&isched.irend, tready, 0);
		}

		if(isched.vmq != nil && (isched.runhd == nil || ++cycles > Vmcycles)){
			iyield();
			cycles = 0;
		}

		r = isched.runhd;
		if(r != nil) {
			o = r->osenv;
			up->env = o;
			/*
			 * Taken before the quantum: a Prog that exits during it
			 * is freed by the time the audit below runs, and every
			 * catch so far has printed the poison of a freed Prog
			 * where its pc should be -- which is itself the finding
			 * (the imbalance comes with an exit), and the reason to
			 * read these two fields first.
			 */
			pid = r->pid;
			modname = r->reg.M != nil && r->reg.M->m != nil ? r->reg.M->m->name : "?";

			FPrestore(&o->fpu);
			r->xec(r);
			FPsave(&o->fpu);
			/*
			 * #635: a queued Prog's saved PC goes bad while some
			 * OTHER Prog runs. Every check at the points where a PC
			 * is written stays silent; only xec()'s check at the
			 * victim's next quantum fires. So after each quantum,
			 * look at every Prog in the run queue: the first one
			 * found bad names the quantum -- this Prog, this module,
			 * this pc -- during which it happened.
			 */
			{
				Prog *q;
				for(q = isched.runhd; q != nil; q = q->link)
					if(q != r && q->reg.M != nil && q->reg.M != H && q->reg.M->compiled && ((uintptr)q->reg.PC & 3) && !(q->flags & Pbadpc)){
						q->flags |= Pbadpc;
						print("BUG: prog %d %s R.PC=%p (prog %p) went bad during the quantum of prog %d %s at pc %p (prog %p, state %d)\n",
							q->pid, q->reg.M->m? q->reg.M->m->name : "?", q->reg.PC, q->reg.M->m? (void*)q->reg.M->m->prog : nil,
							pid, modname, r->reg.PC, r->reg.M != H && r->reg.M->m? (void*)r->reg.M->m->prog : nil, r->state);
					}
			}

			if(up->nerrlab != nerr){
				/*
				 * The PC as an instruction index into the module,
				 * which its .sbl file turns into a source line --
				 * the native address of a JIT-compiled instruction
				 * says nothing to anyone.
				 */
				int i, n;

				n = up->nerrlab;
				print("vmachine: error stack %d, expected %d, after prog %d %s (%s); re-armed\n",
					n, nerr, pid, modname,
					isched.runhd == r || r->pid == pid ? "still live" : "exited in this quantum");
				/*
				 * Each label records the pc of the waserror() that
				 * pushed it, so a label left behind names its own
				 * leaker; and the label that should be here but was
				 * popped still holds who pushed it, since poperror()
				 * only counts down. Print what is at every index from
				 * the lower count to the higher.
				 */
				if(n > NERR)
					n = NERR;
				for(i = nerr < n ? nerr : n; i < (nerr > n ? nerr : n) && i < NERR; i++)
					print("vmachine:   errlab[%d] pushed at pc %#p sp %#p\n",
						i, up->errlab[i].pc, up->errlab[i].sp);
				/*
				 * Repairing the COUNT is not enough. When it came
				 * up short, the slot this function's own label lived
				 * in has been reused by whoever pushed after the
				 * extra pop -- rread, rwrite, kopen have all been
				 * seen there -- and the next error() would land in
				 * that dead frame. So drop to below this function's
				 * slot and go round the outer loop, whose waserror()
				 * pushes a fresh label there. The board ran 41
				 * minutes on a count-only repair before a longjmp
				 * into rread's ghost ended in "Double release".
				 */
				up->env = &up->defenv;
				up->nerrlab = nerr - 1;
				goto rearm;
			}

			if(isched.runhd != nil)
			if(r == isched.runhd)
			if(isched.runhd != isched.runtl) {
				chkprog(r->link, "rotate");
				isched.runhd = r->link;
				r->link = nil;
				isched.runtl->link = r;
				isched.runtl = r;
			}
			up->env = &up->defenv;
			/*
			 * Collect periodically, and immediately once the heap
			 * is half gone.
			 *
			 * This used to run a collection quantum after EVERY
			 * Prog quantum, which is what the native kernel has
			 * always done and what the emulator stopped doing long
			 * ago -- emu/port/dis.c has carried this same counter
			 * and this same memlow() valve for years. The two
			 * files are otherwise the same code, and the giveaway
			 * that they diverged rather than differing by design
			 * is right above: gcbusy, gcidle, gcidlepass and
			 * gcpartial are all declared in this file and none of
			 * them was ever assigned, because the throttle that
			 * counts them never came across.
			 *
			 * It costs more here than it ever did in emu. Every
			 * Limbo process pays it, and on this machine the
			 * Ethernet driver, its 9P server and the application
			 * are all Limbo -- so a packet crosses the collector
			 * several times on its way through. Measured on the
			 * hardware: a 1MB TCP round trip went from 20KB/s to
			 * 347KB/s with the collector held off entirely, and
			 * board-to-host from 75KB/s to 2.2MB/s. That is not
			 * the collector being slow, it is the collector being
			 * asked to run tens of thousands of times a second.
			 *
			 * Holding it off is not an option -- it leaks by
			 * construction. Running it 1/256 as often is, because
			 * the heap here is 16MB and memlow() trips at half of
			 * that: with room to spare collection is lazy, and
			 * under real pressure the second test fires on every
			 * pass and the old behaviour comes straight back. The
			 * throttle gives away floating garbage, which is
			 * bounded by the valve, and buys back the time.
			 */
			if(isched.runhd != nil)
			if((++gccounter & 0xFF) == 0 || memlow())
			if (up->iprog == nil) {
				gcbusy++;
				up->type = BusyGC;
				pushrun(up->prog);
				rungc(isched.head);
				up->type = Interp;
				delrunq(up->prog);
			} else
				print("up->iprog not nil (%lux)\n", up->iprog);
		}
	}
rearm:
	;
    }
}

void
disinit(void *a)
{
	Prog *p;
	Osenv *o;
	Module *root;
	char *initmod = a;

	if(waserror())
		panic("disinit error: %r");

	vm0.vsched = &sched0;
	up->vm = &vm0;

	print("Initial Dis: \"%s\"\n", initmod);

	fmtinstall('D', Dconv);

	addclock0link(accountant, MS2HZ);

	FPinit();
	FPsave(&up->env->fpu);

	opinit();
	modinit();
	typesperm = 0;		/* builtin types are shared and permanent; a module's are its VM's (interp.h) */
	excinit();

	root = load(initmod);
	if(root == 0) {
		kgerrstr(up->genbuf, sizeof up->genbuf);
		panic("loading \"%s\": %s", initmod, up->genbuf);
	}

	p = schedmod(root);

	memmove(p->osenv, up->env, sizeof(Osenv));
	o = p->osenv;
	incref(&o->pgrp->r);
	incref(&o->fgrp->r);
	if(o->egrp != nil)
		incref(&o->egrp->r);
	if(o->sigs != nil)
		incref(&o->sigs->r);
	o->user = nil;
	kstrdup(&o->user, up->env->user);
	o->errstr = o->errbuf0;
	o->syserrstr = o->errbuf1;

	isched.idle = 1;

	if(kopen("#c/cons", OREAD) != 0)
		panic("failed to make fd0 from #c/cons");
	kopen("#c/cons", OWRITE);
	kopen("#c/cons", OWRITE);

	poperror();
	vmachine(nil);
}

void
pushrun(Prog *p)
{
	if(p->addrun != nil)
		panic("pushrun addrun");
	p->state = Pready;
	chkprog(p, "pushrun");
	p->link = isched.runhd;
	isched.runhd = p;
	if(p->link == nil)
		isched.runtl = p;
}
