/*
 * Imported from upstream Inferno os/port/proc.c.
 *
 * DIVERGENCE FROM UPSTREAM: the embedded Locks in procalloc and Schedq
 * are named, and their call sites are explicit. Upstream uses Plan 9
 * anonymous members and passes the container; clang has no working
 * equivalent (see os/bcm2837/README.md).
 *
 * Note what "lock(runq)" meant and still means: runq is an ARRAY, so
 * that call locked runq[0], which serves as the single master lock
 * covering every run queue -- while rq = &runq[p->pri] selects which
 * queue is actually manipulated. It is now spelled lock(&runq[0].l),
 * which is the same lock. Rewriting it as lock(&rq->l) would look
 * tidier and would be a different, finer-grained locking discipline
 * than the one this code was written against.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	<interp.h>

Ref	pidalloc;

struct
{
	Lock	l;
	Proc*	arena;
	Proc*	free;
}procalloc;

typedef struct
{
	Lock	l;
	Proc*	head;
	Proc*	tail;
}Schedq;

static Schedq	runq[Nrq];
static ulong	occupied;
int	nrdy;

char *statename[] =
{			/* BUG: generate automatically */
	"Dead",
	"Moribund",
	"Ready",
	"Scheding",
	"Running",
	"Queueing",
	"Wakeme",
	"Broken",
	"Stopped",
	"Rendez",
};

/*
 * Always splhi()'ed.
 */
void
schedinit(void)		/* never returns */
{
	Proc *p;

	setlabel(&m->sched);
	/*
	 * CAPTURE the outgoing process before clearing m->proc -- and
	 * understand why, because this line held the whole SMP port
	 * hostage for a day. `up` is not a variable any more: it is
	 * m->proc behind a macro. Upstream's code nils m->proc early
	 * and goes on handling `up`, which upstream could do because
	 * its `up` was a separate global that kept its value. Here the
	 * nil went through the macro and every following reference --
	 * the state switch, ready(), the mach clear -- quietly operated
	 * on address zero. Preempted processes were never re-queued,
	 * sleeping processes kept a stale mach forever, and runproc
	 * rejected them on the mach test until the machine sat with
	 * four idle cores, two Ready processes, and half a billion
	 * futile lock acquisitions. The trace that convicted it was a
	 * SETm with no CLRm ever following.
	 */
	p = up;
	if(p) {
		m->proc = nil;
		/*
		 * mach is cleared BEFORE the proc becomes visible on the
		 * run queue: by the time this label resumes, setlabel()
		 * on the outgoing side has completed and the old core
		 * has no further claim. Clearing it after ready() would
		 * publish a Ready process that other cores' runproc
		 * must reject on the mach test.
		 */
		p->mach = nil;
		coherence();
		switch(p->state) {
		case Running:
			ready(p);
			break;
		case Moribund:
			p->state = Dead;
/*
			edfstop(p);
			if(p->edf){
				free(p->edf);
				p->edf = nil;
			}
*/
			/*
			 * Holding locks from pexit:
			 * 	procalloc
			 */
			p->qnext = procalloc.free;
			procalloc.free = p;
			unlock(&procalloc.l);
			break;
		}
	}
	sched();
}

/*
 * Kernel image bounds, from the linker script. Both boards define
 * these; text/rodata/data is [_start, __bss_start).
 */
extern char _start[], __bss_start[];

void
sched(void)
{
	/*
	 * sched() switches stacks, so it must be running on the stack it
	 * thinks it is. up and the actual stack pointer disagreeing is
	 * the one thing that makes every later symptom incomprehensible:
	 * setlabel() below records the WRONG stack into up->sched, and
	 * the eventual gotolabel() resumes the process somewhere it never
	 * ran, with the corruption surfacing an unbounded time later as a
	 * bad PSTATE, a jump into data, or a fault from an exception
	 * level this kernel never uses.
	 *
	 * Check it here, where the question is cheap and the answer is
	 * exact, rather than inferring it afterwards from wreckage.
	 */
	if(up != nil && up->kstack != nil){
		uintptr sp = (uintptr)&sp;	/* a local IS the stack */

		if(sp < (uintptr)up->kstack || sp > (uintptr)up->kstack + KSTACK)
			panic("sched: pid %lud sp %lux outside kstack %lux..%lux",
				up->pid, sp, (uintptr)up->kstack,
				(uintptr)up->kstack + KSTACK);
	}

	if(up) {
		splhi();
		procsave(up);
		if(setlabel(&up->sched)) {
			procrestore(up);
			spllo();
			return;
		}
		gotolabel(&m->sched);
	}
	up = runproc();
	up->state = Running;
	up->mach = MACHP(m->machno);	/* m might be a fixed address; use MACHP */
	m->proc = up;

	/*
	 * gotolabel() is an unconditional branch through up->sched.pc, so a
	 * bad word here fails at whatever address it lands on rather than
	 * where it was written. Label is also the first field of Proc, which
	 * makes it the first thing an overrun into a Proc destroys. Check it
	 * while it can still be attributed.
	 */
	if(up->sched.pc < (uintptr)_start || up->sched.pc >= (uintptr)__bss_start)
		panic("sched: pid %lud label pc %lux not in text (sp %lux kstack %lux)",
			up->pid, up->sched.pc, up->sched.sp, (uintptr)up->kstack);

	/*
	 * The label's sp matters as much as its pc: gotolabel installs it
	 * directly, so a bad one puts the resumed process on a stack it
	 * does not own, and the damage only surfaces once something
	 * overflows into whatever is next in .bss.
	 */
	if(up->sched.sp < (uintptr)up->kstack ||
	   up->sched.sp > (uintptr)up->kstack + KSTACK)
		panic("sched: pid %lud label sp %lux outside kstack %lux..%lux",
			up->pid, up->sched.sp, (uintptr)up->kstack,
			(uintptr)up->kstack + KSTACK);

	gotolabel(&up->sched);
}

void
ready(Proc *p)
{
	int s;
	Schedq *rq;

	s = splhi();
/*
	if(edfready(p)){
		splx(s);
		return;
	}
*/
	rq = &runq[p->pri];
	lock(&runq[0].l);
	p->rnext = 0;
	if(rq->tail)
		rq->tail->rnext = p;
	else
		rq->head = p;
	rq->tail = p;

	nrdy++;
	occupied |= 1<<p->pri;
	p->state = Ready;
	unlock(&runq[0].l);
	splx(s);
	idlewake();	/* an idle core may be waiting in wfe for exactly this */
}

int
anyready(void)
{
	/* same priority only */
	return occupied & (1<<up->pri);
}

int
anyhigher(void)
{
	return occupied & ((1<<up->pri)-1);
}

int
preemption(int tick)
{
	if(up != nil && up->state == Running && !up->preempted &&
	   (anyhigher() || tick && anyready())){
		up->preempted = 1;
		sched();
		splhi();
		up->preempted = 0;
		return 1;
	}
	return 0;
}
		
Proc*
runproc(void)
{
	Proc *p, *l;
	Schedq *rq, *erq;

	erq = runq + Nrq - 1;
loop:
	splhi();
	/*
	 * Walk EVERY priority looking for something this core may run,
	 * and only idle when none of them holds one. The first SMP
	 * version restarted the whole search whenever the best queue
	 * held only processes wired to another core -- which, with the
	 * run queue non-empty, is a hard spin at splhi hammering the run
	 * queue lock from every idle core at once. Three cores did
	 * exactly that to the fourth within a second of the first wired
	 * process becoming ready, and the machine stalled inside its own
	 * scheduler.
	 */
	for(rq = runq; ; rq++){
		if(rq > erq){
			idlehands();
			spllo();
			goto loop;
		}
		if(rq->head == 0)
			continue;
		/*
		 * Peek WITHOUT the lock first. Three idle cores taking
		 * the run-queue lock just to discover a queue holds only
		 * work wired to somebody else turned the scheduler into
		 * a lock convoy -- every PC sample on every core landed
		 * in runproc, canlock or _tas, and the machine stalled
		 * inside its own scheduler with all four cores busy.
		 * The peek races with concurrent dequeues, harmlessly:
		 * a stale sighting is re-checked under the lock, a
		 * missed one is caught on the next pass, and ready()'s
		 * sev ends any wait that matters.
		 */
		for(p = rq->head; p != nil; p = p->rnext)
			if(p->wired == nil || p->wired == MACHP(m->machno))
				break;
		if(p == nil)
			continue;	/* nothing here for this core */
		if(!canlock(&runq[0].l))
			continue;	/* busy; try the next queue, not the world */
		l = nil;
		for(p = rq->head; p != nil; l = p, p = p->rnext){
			if(p->wired != nil && p->wired != MACHP(m->machno))
				continue;
			if(p->mp == nil || p->mp == MACHP(m->machno) ||
			   p->movetime < MACHP(0)->ticks)
				break;
		}
		if(p == nil){
			/* second pass: anything here this core MAY run */
			for(p = rq->head, l = nil; p != nil; l = p, p = p->rnext)
				if(p->wired == nil || p->wired == MACHP(m->machno))
					break;
		}
		if(p != nil)
			break;		/* found one; rq and l are set */
		unlock(&runq[0].l);	/* the peek was stale; move on */
	}
	/*
	 * Choose the first one we last ran on this processor at this
	 * level, or that hasn't moved recently.
	 *
	 * l must come out of this as p's PREDECESSOR: the unlink below
	 * uses it for both "l->rnext = p->rnext" and "rq->tail = l".
	 * Upstream never advances it -- the loop increments only p -- so
	 * l is always nil, and choosing anything other than the head then
	 * runs "rq->head = p->rnext", which drops every process ahead of
	 * p off the queue. They are never scheduled again, nrdy is
	 * decremented once for all of them, and the level's bit in
	 * "occupied" is left describing a queue that no longer holds
	 * them.
	 *
	 * It survives upstream because on a uniprocessor the head almost
	 * always satisfies the test and the loop breaks immediately.
	 * That makes it latent rather than absent, which is the worst
	 * kind of bug to inherit.
	 *
	 * When the loop runs to completion p is nil and we fall back to
	 * the head, so l has to be reset -- at that point it is the TAIL,
	 * not the head's predecessor.
	 */
	/*
	 * p->mach==0 only when the process's state is fully saved. A
	 * nonzero mach here means the proc was readied while its old
	 * core is still in the act of switching away from it -- a real
	 * window on SMP -- and running it now would resume a context
	 * that is still being written. Upstream answered with "goto
	 * loop", which on a uniprocessor retried into progress; with
	 * this core looping and the queue otherwise empty it became an
	 * invisible infinite rejection -- half a billion lock
	 * acquisitions, five dequeues, and a scheduler that looked
	 * haunted. Say so (rate-limited) while the window is studied,
	 * and retry.
	 */
	if(p == 0 || p->mach) {
		unlock(&runq[0].l);
		goto loop;
	}
	if(p->rnext == nil)
		rq->tail = l;
	if(l)
		l->rnext = p->rnext;
	else
		rq->head = p->rnext;
	if(rq->head == nil){
		rq->tail = nil;
		occupied &= ~(1<<p->pri);
	}
	nrdy--;
	if(p->dbgstop){
		p->state = Stopped;
		unlock(&runq[0].l);
		goto loop;
	}
	if(p->state != Ready)
		print("runproc %s %lud %s\n", p->text, p->pid, statename[p->state]);
	unlock(&runq[0].l);
	p->state = Scheding;
	if(p->mp != MACHP(m->machno))
		p->movetime = MACHP(0)->ticks + HZ/10;
	p->mp = MACHP(m->machno);

/*
	if(edflock(p)){
		edfrun(p, rq == &runq[PriEdf]);	// start deadline timer and do admin
		edfunlock();
	}
*/
	return p;
}

int
setpri(int pri)
{
	int p;

	/* called by up so not on run queue */
	p = up->pri;
	up->pri = pri;
	if(up->state == Running && anyhigher())
		sched();
	return p;
}

Proc*
newproc(void)
{
	Proc *p;

	lock(&procalloc.l);
	for(;;) {
		if(p = procalloc.free)
			break;

		unlock(&procalloc.l);
		resrcwait("no procs");
		lock(&procalloc.l);
	}
	procalloc.free = p->qnext;
	unlock(&procalloc.l);

	p->type = Unknown;
	p->state = Scheding;
	p->pri = PriNormal;
	p->psstate = "New";
	p->mach = 0;
	p->qnext = 0;
	p->fpstate = FPINIT;
	p->kp = 0;
	p->killed = 0;
	p->swipend = 0;
	p->mp = 0;
	p->wired = nil;		/* stale wiring on a recycled Proc is a proc
				 * no core will ever agree to run */
	p->movetime = 0;
	p->delaysched = 0;
	p->edf = nil;
	memset(&p->defenv, 0, sizeof(p->defenv));
	p->env = &p->defenv;
	p->dbgreg = 0;
	kstrdup(&p->env->user, "*nouser");
	p->env->errstr = p->env->errbuf0;
	p->env->syserrstr = p->env->errbuf1;

	p->pid = incref(&pidalloc);
	if(p->pid == 0)
		panic("pidalloc");
	if(p->kstack == 0)
		p->kstack = smalloc(KSTACK);

	/*
	 * Guard word at the base of the kernel stack.
	 *
	 * A kernel stack that runs off its bottom does not fault -- it
	 * keeps descending into whatever the pool handed out below it, so
	 * the failure appears somewhere else entirely and much later. The
	 * guard turns "sp is somewhere impossible" into "this process
	 * overflowed its stack", which are very different bugs.
	 */
	*(ulong*)p->kstack = KSTACKGUARD;
	addprog(p);

	return p;
}

void
procinit(void)
{
	Proc *p;
	int i;

	procalloc.free = xalloc(conf.nproc*sizeof(Proc));
	procalloc.arena = procalloc.free;

	p = procalloc.free;
	for(i=0; i<conf.nproc-1; i++,p++)
		p->qnext = p+1;
	p->qnext = 0;

	debugkey('p', "processes", procdump, 0);
}

void
sleep(Rendez *r, int (*f)(void*), void *arg)
{
	int s;

	if(up == nil)
		panic("sleep() not in process (%lux)", getcallerpc(&r));
	/*
	 * spl is to allow lock to be called
	 * at interrupt time. lock is mutual exclusion
	 */
	s = splhi();

	lock(&up->rlock);
	lock(&r->l);

	/*
	 * if killed or condition happened, never mind
	 */
	if(up->killed || f(arg)){
		unlock(&r->l);
	}else{

		/*
		 * now we are committed to
		 * change state and call scheduler
		 */
		if(r->p != nil) {
			print("double sleep pc=0x%lux %lud %lud r=0x%lux\n", getcallerpc(&r), r->p->pid, up->pid, r);
			dumpstack();
			panic("sleep");
		}
		up->state = Wakeme;
		r->p = up;
		unlock(&r->l);
		up->swipend = 0;
		up->r = r;	/* for swiproc */
		unlock(&up->rlock);

		sched();
		splhi();	/* sched does spllo */

		lock(&up->rlock);
		up->r = nil;
	}

	if(up->killed || up->swipend) {
		up->killed = 0;
		up->swipend = 0;
		unlock(&up->rlock);
		splx(s);
		error(Eintr);
	}
	unlock(&up->rlock);
	splx(s);
}

int
tfn(void *arg)
{
	return MACHP(0)->ticks >= up->twhen || (*up->tfn)(arg);
}

void
tsleep(Rendez *r, int (*fn)(void*), void *arg, int ms)
{
	ulong when;
	Proc *f, **l;

	if(up == nil)
		panic("tsleep() not in process (0x%lux)", getcallerpc(&r));

	when = MS2TK(ms)+MACHP(0)->ticks;
	lock(&talarm.l);
	/* take out of list if checkalarm didn't */
	if(up->trend) {
		l = &talarm.list;
		for(f = *l; f; f = f->tlink) {
			if(f == up) {
				*l = up->tlink;
				break;
			}
			l = &f->tlink;
		}
	}
	/* insert in increasing time order */
	l = &talarm.list;
	for(f = *l; f; f = f->tlink) {
		if(f->twhen >= when)
			break;
		l = &f->tlink;
	}
	up->trend = r;
	up->twhen = when;
	up->tfn = fn;
	up->tlink = *l;
	*l = up;
	unlock(&talarm.l);

	if(waserror()){
		up->twhen = 0;
		nexterror();
	}
	sleep(r, tfn, arg);
	up->twhen = 0;
	poperror();
}

int
wakeup(Rendez *r)
{
	Proc *p;
	int s;

	s = splhi();
	lock(&r->l);
	p = r->p;
	if(p){
		r->p = nil;
		if(p->state != Wakeme)
			panic("wakeup: state");
		ready(p);
	}
	unlock(&r->l);
	splx(s);
	return p != nil;
}

void
swiproc(Proc *p, int interp)
{
	ulong s;
	Rendez *r;

	if(p == nil)
		return;

	s = splhi();
	lock(&p->rlock);
	if(!interp)
		p->killed = 1;
	r = p->r;
	if(r != nil) {
		lock(&r->l);
		if(r->p == p){
			p->swipend = 1;
			r->p = nil;
			ready(p);
		}
		unlock(&r->l);
	}
	unlock(&p->rlock);
	splx(s);
}

void
notkilled(void)
{
	lock(&up->rlock);
	up->killed = 0;
	unlock(&up->rlock);
}

void
pexit(char*, int)
{
	Osenv *o;

	up->alarm = 0;

	o = up->env;
	if(o != nil){
		closefgrp(o->fgrp);
		closepgrp(o->pgrp);
		closeegrp(o->egrp);
		closesigs(o->sigs);
	}

	/* Sched must not loop for this lock */
	lock(&procalloc.l);

/*
	edfstop(up);
*/
	up->state = Moribund;
	sched();
	panic("pexit");
}

Proc*
proctab(int i)
{
	return &procalloc.arena[i];
}

void
procdump(void)
{
	int i;
	char *s;
	Proc *p;
	char tmp[14];

	for(i=0; i<conf.nproc; i++) {
		p = &procalloc.arena[i];
		if(p->state == Dead)
			continue;

		s = p->psstate;
		if(s == nil)
			s = "kproc";
		if(p->state == Wakeme)
			snprint(tmp, sizeof(tmp), " /%.8lux", p->r);
		else
			*tmp = '\0';
		print("%lux:%3lud:%14s pc %.8lux %s/%s qpc %.8lux pri %d%s\n",
			p, p->pid, p->text, p->pc, s, statename[p->state], p->qpc, p->pri, tmp);
	}
}

void
kproc(char *name, void (*func)(void *), void *arg, int flags)
{
	Proc *p;
	Pgrp *pg;
	Fgrp *fg;
	Egrp *eg;

	p = newproc();
	p->psstate = 0;
	p->kp = 1;

	p->fpsave = up->fpsave;
	p->scallnr = up->scallnr;
	p->nerrlab = 0;

	kstrdup(&p->env->user, up->env->user);
	if(flags & KPDUPPG) {
		pg = up->env->pgrp;
		incref(&pg->r);
		p->env->pgrp = pg;
	}
	if(flags & KPDUPFDG) {
		fg = up->env->fgrp;
		incref(&fg->r);
		p->env->fgrp = fg;
	}
	if(flags & KPDUPENVG) {
		eg = up->env->egrp;
		if(eg != nil)
			incref(&eg->r);
		p->env->egrp = eg;
	}

	kprocchild(p, func, arg);

	strcpy(p->text, name);

	ready(p);
}

void
errorf(char *fmt, ...)
{
	va_list arg;
	char buf[PRINTSIZE];

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	error(buf);
}

/*
 * Refuse to push an error label past the end of up->errlab.
 *
 * NERR is 30, which is generous for legitimate nesting -- so hitting it
 * means waserror() calls are leaking, not that the depth is genuine.
 * Saying so here names the moment it happens; without it the array
 * simply overflows into the rest of Proc and the damage surfaces later
 * as a jump to a nonsense address.
 */
void
errlabcheck(void)
{
	if(up == nil)
		panic("waserror: not in a process");
	if(up->nerrlab >= NERR)
		panic("waserror: error stack overflow, nerrlab %d pc %lux",
			up->nerrlab, getcallerpc(&up));
}

void
error(char *err)
{
	if(up == nil)
		panic("error(%s) not in a process", err);
	spllo();
	if(up->nerrlab > NERR)
		panic("error stack too deep");
	if(err != up->env->errstr)
		kstrcpy(up->env->errstr, err, ERRMAX);
	setlabel(&up->errlab[NERR-1]);
	nexterror();
}

#include "errstr.h"

/* Set kernel error string */
void
kerrstr(char *err, uint size)
{

	char tmp[ERRMAX];

	kstrcpy(tmp, up->env->errstr, sizeof(tmp));
	kstrcpy(up->env->errstr, err, ERRMAX);
	kstrcpy(err, tmp, size);
}

/* Get kernel error string */
void
kgerrstr(char *err, uint size)
{
	char tmp[ERRMAX];

	kstrcpy(tmp, up->env->errstr, sizeof(tmp));
	kstrcpy(up->env->errstr, err, ERRMAX);
	kstrcpy(err, tmp, size);
}

/* Set kernel error string, using formatted print */
void
kwerrstr(char *fmt, ...)
{
	va_list arg;
	char buf[ERRMAX];

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	kstrcpy(up->env->errstr, buf, ERRMAX);
}

void
werrstr(char *fmt, ...)
{
	va_list arg;
	char buf[ERRMAX];

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	kstrcpy(up->env->errstr, buf, ERRMAX);
}

void
nexterror(void)
{
	gotolabel(&up->errlab[--up->nerrlab]);
}

/* for dynamic modules - functions not macros */
	
void*
waserr(void)
{
	up->nerrlab++;
	return &up->errlab[up->nerrlab-1];
}

void
poperr(void)
{
	up->nerrlab--;
}

char*
enverror(void)
{
	return up->env->errstr;
}

void
exhausted(char *resource)
{
	char buf[64];

	snprint(buf, sizeof(buf), "no free %s", resource);
	iprint("%s\n", buf);
	error(buf);
}

/*
 *  change ownership to 'new' of all processes owned by 'old'.  Used when
 *  eve changes.
 */
void
renameuser(char *old, char *new)
{
	Proc *p, *ep;
	Osenv *o;

	ep = procalloc.arena+conf.nproc;
	for(p = procalloc.arena; p < ep; p++) {
		o = &p->defenv;
		if(o->user != nil && strcmp(o->user, old) == 0)
			kstrdup(&o->user, new);
	}
}

int
return0(void*)
{
	return 0;
}

void
setid(char *name, int owner)
{
	if(!owner || iseve())
		kstrdup(&up->env->user, name);
}

void
rptwakeup(void *o, void *ar)
{
	Rept *r;

	r = ar;
	if(r == nil)
		return;
	lock(&r->l);
	r->o = o;
	unlock(&r->l);
	wakeup(&r->r);
}

static int
rptactive(void *a)
{
	Rept *r = a;
	int i;
	lock(&r->l);
	i = r->active(r->o);
	unlock(&r->l);
	return i;
}

static void
rproc(void *a)
{
	long now, then;
	ulong t;
	int i;
	void *o;
	Rept *r;

	r = a;
	t = r->t;

Wait:
	sleep(&r->r, rptactive, r);
	lock(&r->l);
	o = r->o;
	unlock(&r->l);
	then = TK2MS(MACHP(0)->ticks);
	for(;;){
		tsleep(&up->sleep, return0, nil, t);
		now = TK2MS(MACHP(0)->ticks);
		if(waserror())
			break;
		i = r->ck(o, now-then);
		poperror();
		if(i == -1)
			goto Wait;
		if(i == 0)
			continue;
		then = now;
		acquire();
		if(waserror()) {
			release();
			break;
		}
		r->f(o);
		poperror();
		release();
	}
	pexit("", 0);
}

void*
rptproc(char *s, int t, void *o, int (*active)(void*), int (*ck)(void*, int), void (*f)(void*))
{
	Rept *r;

	r = mallocz(sizeof(Rept), 1);
	if(r == nil)
		return nil;
	r->t = t;
	r->active = active;
	r->ck = ck;
	r->f = f;
	r->o = o;
	kproc(s, rproc, r, KPDUP);
	return r;
}
