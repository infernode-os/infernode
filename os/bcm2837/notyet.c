/*
 * Functions os/port/proc.c calls that live in os/port files not yet
 * imported.
 *
 * Each is marked with the file that owns it upstream. When that file is
 * imported the corresponding definition here must be DELETED, not left
 * to shadow it -- and the linker will insist, since a duplicate symbol
 * is an error rather than a silent preference. That is deliberate: it
 * makes this file self-retiring rather than something to remember.
 *
 * The small primitives are implemented properly rather than stubbed,
 * because a stub that silently does nothing is worse than absent when
 * the caller depends on the effect. The ones that genuinely cannot work
 * yet say so.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "interp.h"

/*
 * chan.c -- reference counting.
 *
 * Implemented, not stubbed: proc.c uses these to keep Pgrp, Fgrp and
 * Egrp alive across a fork, and a no-op would free a namespace out from
 * under a running process.
 */
int
incref(Ref *r)
{
	int x;

	lock(&r->l);
	x = ++r->ref;
	unlock(&r->l);
	return x;
}

int
decref(Ref *r)
{
	int x;

	lock(&r->l);
	x = --r->ref;
	unlock(&r->l);
	if(x < 0)
		panic("decref: reference count went negative, pc=%lux",
			(ulong)getcallerpc(&r));
	return x;
}

/*
 * chan.c -- bounded string copy.
 *
 * Implemented because proc.c uses it for error strings, and truncating
 * correctly matters more than usual when the thing being copied is a
 * report of what already went wrong.
 */
void
kstrcpy(char *s, char *t, int ns)
{
	int nt;

	nt = strlen(t);
	if(nt+1 <= ns){
		memmove(s, t, nt+1);
		return;
	}
	if(ns < 4){
		if(ns > 0)
			s[0] = 0;
		return;
	}
	/* keep the head, mark the truncation so it is not mistaken for the whole */
	memmove(s, t, ns-4);
	memmove(s+ns-4, "...", 4);
}

void
kstrdup(char **p, char *s)
{
	int n;
	char *t;

	n = strlen(s) + 1;
	t = malloc(n);
	if(t == nil)
		return;
	memmove(t, s, n);
	free(*p);
	*p = t;
}

/*
 * devcons.c
 */
int
iseve(void)
{
	/*
	 * "Is the caller the host owner?" With no user model yet there is
	 * exactly one principal, and it is that one. This becomes a real
	 * check when devcons and the user machinery are imported -- until
	 * then it must not be used to gate anything security-relevant.
	 */
	return 1;
}

int
iprint(char *fmt, ...)
{
	va_list arg;
	static char buf[256];
	int s;

	/*
	 * print() from interrupt context. Masks interrupts rather than
	 * taking the console lock, because the caller may already hold it.
	 */
	s = splhi();
	va_start(arg, fmt);
	vsnprint(buf, sizeof buf, fmt, arg);
	va_end(arg);
	putstrn(buf, strlen(buf));
	splx(s);

	return strlen(buf);
}

/*
 * chan.c -- channel lifetime.
 *
 * pgrp.c's namespace teardown calls these to release the Chans a mount
 * table holds. Nothing creates a Chan yet, so those tables are empty and
 * these are never reached with real work to do -- which is the only
 * reason a stub is acceptable here. The moment chan.c lands these must
 * go, and the linker will say so.
 */
void
cclose(Chan *c)
{
	USED(c);
}

Chan*
cclone(Chan *c)
{
	USED(c);
	panic("cclone: chan.c not imported yet");
	return nil;
}

void
putmhead(Mhead *m)
{
	USED(m);
}

/*
 * closepgrp, closefgrp, closesigs and resrcwait were stubbed here.
 * os/port/pgrp.c now provides the real ones, which genuinely tear down
 * a namespace rather than doing nothing, so the stubs are gone.
 *
 * closeegrp still belongs to devenv.c, which is not imported.
 */
void
closeegrp(Egrp *e)
{
	USED(e);
}


/*
 * dis.c -- the Dis VM.
 *
 * acquire/release manage the global VM lock and are only reached by
 * code actually running Dis, so panicking is right: getting there before
 * libinterp is linked means something is running that should not be.
 *
 * addprog is different, and it is worth saying why rather than treating
 * the whole file as one category. newproc() calls it UNCONDITIONALLY
 * for every process, kernel ones included -- but all it does is allocate
 * the per-process Prog and point it at the process's Osenv. It touches
 * no VM state and needs nothing libinterp provides, so it is implemented
 * properly here. Panicking would have made newproc unusable, and a
 * no-op would have left every Proc with a nil prog for something else
 * to trip over later.
 */
void
acquire(void)
{
	panic("acquire: Dis VM not linked yet");
}

void
release(void)
{
	panic("release: Dis VM not linked yet");
}

void
addprog(Proc *p)
{
	Prog *n;

	if((n = p->prog) == nil){
		n = malloc(sizeof(Prog));
		if(n == nil)
			panic("addprog: no memory for Prog");
		p->prog = n;
	} else
		memset(n, 0, sizeof(Prog));
	n->osenv = p->env;
}
