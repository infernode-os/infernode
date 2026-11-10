#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"interp.h"

Proc*
newproc(void)
{
	Proc *p;

	p = malloc(sizeof(Proc));
	if(p == nil)
		return nil;

	p->type = Unknown;
	p->killed = 0;
	p->swipend = 0;
	p->intpend = 0;
	p->env = &p->defenv;
	kstrdup(&p->env->user, "*nouser");
	p->env->errstr = p->env->errbuf0;
	p->env->syserrstr = p->env->errbuf1;
	addprog(p);

	return p;
}

void
Sleep(Rendez *r, int (*f)(void*), void *arg)
{
	lock(&up->rlock);
	lock(&r->l);

	/*
	 * if interrupted or condition happened, never mind
	 */
	/* A revoked released Prog may not sleep again before returning to its VM. */
	if(up->killed || up->intpend || (up->killing == 0 && upkilled()) || f(arg)) {
		unlock(&r->l);
	}else{
		if(r->p != nil)
			panic("double sleep pc=0x%lux %s[%lud] %s[%lud] r=0x%lux\n", getcallerpc(&r), r->p->text, r->p->pid, up->text, up->pid, r);

		r->p = up;
		unlock(&r->l);
		up->swipend = 0;
		up->r = r;	/* for swiproc */
		unlock(&up->rlock);

		osblock();

		lock(&up->rlock);
		up->r = nil;
	}

	if(up->killed || up->swipend || up->intpend || (up->killing == 0 && upkilled())) {
		up->killed = 0;
		up->swipend = 0;
		up->intpend = 0;
		unlock(&up->rlock);
		error(Eintr);
	}
	unlock(&up->rlock);
}

int
Wakeup(Rendez *r)
{
	Proc *p;

	lock(&r->l);
	p = r->p;
	if(p != nil) {
		r->p = nil;
		osready(p);
	}
	unlock(&r->l);
	return p != nil;
}

void
swiproc(Proc *p, int interp)
{
	Rendez *r;
	
	if(p == nil)
		return;

	/*
	 * Pull out of emu Sleep
	 */
	lock(&p->rlock);
	if(!interp)
		p->killed = 1;
	r = p->r;
	if(r != nil) {
		lock(&r->l);
		if(r->p == p){
			p->swipend = 1;
			r->p = nil;
			osready(p);
		}
		unlock(&r->l);
		unlock(&p->rlock);
		return;
	}
	/*
	 * Neither asleep nor (below) in the host: the Prog's kill came while
	 * its proc was between the two, and would be lost, leaving the proc
	 * to block in the Sleep or system call it was about to make, until
	 * that returned of its own accord (a listen: never).  Leave it for
	 * the next one.  Only for a Prog, released (iprog set) and not yet
	 * back in the VM: exportfs interrupts its slaves whether busy or not.
	 */
	if(interp && p->iprog != nil)
		p->intpend = 1;
	unlock(&p->rlock);

	/*
	 * Maybe pull out of Host OS
	 */
	lock(&p->sysio);
	if(p->syscall && p->intwait == 0) {
		p->swipend = 1;
		p->intwait = 1;
		unlock(&p->sysio);
		oshostintr(p);
		return;	
	}
	unlock(&p->sysio);
}

/* Interrupt p only while it still carries this exact released Prog. */
int
swiprogproc(Proc *p, void *iprog)
{
	Rendez *r;

	if(p == nil)
		return 0;
	lock(&p->rlock);
	if(p->iprog != iprog){
		unlock(&p->rlock);
		return 0;
	}
	p->intpend = 1;
	r = p->r;
	if(r != nil){
		lock(&r->l);
		if(r->p == p){
			p->swipend = 1;
			r->p = nil;
			osready(p);
		}
		unlock(&r->l);
		unlock(&p->rlock);
		return 1;
	}
	unlock(&p->rlock);

	lock(&p->sysio);
	if(p->syscall && p->intwait == 0){
		p->swipend = 1;
		p->intwait = 1;
		unlock(&p->sysio);
		oshostintr(p);
		return 1;
	}
	unlock(&p->sysio);
	return 1;
}

void
notkilled(void)
{
	lock(&up->rlock);
	up->killed = 0;
	unlock(&up->rlock);
}

void
osenter(void)
{
	int i;

	lock(&up->sysio);
	up->syscall = 1;
	unlock(&up->sysio);

	/*
	 * After syscall is set: a swiproc that has not seen it has set
	 * intpend before looking, so one or the other is seen.
	 */
	lock(&up->rlock);
	i = up->intpend;
	if(i)
		up->swipend = 1;
	unlock(&up->rlock);
	if(i)
		osleave();	/* raises Eintr */
}

static int	leave(int);

void
osleave(void)
{
	if(leave(0))
		error(Eintr);
}

/*
 * osleave for a host call that did its work: an interrupt that came while
 * it ran is not raised, where it would throw away what the call had done
 * -- bytes read from a socket, gone from the host's buffer, so that a
 * devssl stream lost part of a record ("bad digest") and the connection,
 * and every mount over it, was hung up.  It is dropped: the call is over.
 * A killed Prog is still found killed at its next sleep and on its way
 * back to the VM (upkilled); an exportfs worker's interrupt was for the
 * request whose call has now finished, and kept, it interrupted the
 * worker's next request ("clone failed: interrupted").
 */
void
osleavekeep(void)
{
	leave(1);
}

static int
leave(int keep)
{
	int r;

	lock(&up->rlock);
	r = up->swipend;
	up->swipend = 0;
	if(r)
		up->intpend = 0;	/* the one interrupt: raised by the caller, or dropped */
	unlock(&up->rlock);

	lock(&up->sysio);
	up->syscall = 0;
	unlock(&up->sysio);

	/* Cleared by the signal/note/exception handler.
	 * The signal should arrive almost immediately; if it hasn't
	 * after a bounded number of yields, force-clear to avoid
	 * permanent busy-wait (seen on macOS ARM64 when the signal
	 * handler returns early due to type != Interp or races).
	 */
	if(up->intwait) {
		int i;
		for(i = 0; i < 1000; i++) {
			if(!up->intwait)
				break;
			osyield();
		}
		up->intwait = 0;
	}

	return r != 0 && !keep;
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
	Wakeup(&r->r);
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

	up->env->fgrp = newfgrp(nil);
	r = a;
	t = (ulong)r->t;

Wait:
	Sleep(&r->r, rptactive, r);
	lock(&r->l);
	o = r->o;
	unlock(&r->l);
	then = osmillisec();
	for(;;){
		osmillisleep(t);
		now = osmillisec();
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
	kproc(s, rproc, r, KPDUPPG);
	return r;
}
