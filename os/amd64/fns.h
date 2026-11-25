/*
 * os/amd64/fns.h -- the machine functions os/port asks for.
 *
 * The shape is ../arm64/fns.h's: the machine's own primitives first,
 * then waserror(), then ../port/portfns.h so every os/port source sees
 * the same declarations it does upstream.
 */

#ifndef _OS_AMD64_FNS_H_
#define _OS_AMD64_FNS_H_

/* arch.S: setjmp/longjmp for the kernel, and the lock primitive */
__attribute__((returns_twice)) int	setlabel(Label*);
void	gotolabel(Label*);
ulong	_tas(ulong*);

/* arch.c: interrupt masking.  The saved value is RFLAGS. */
int	splhi(void);
int	spllo(void);
void	splx(int);
int	islo(void);

/* arch.c: x86 is a coherent machine; the barrier orders the stores */
void	coherence(void);

/* clock.c: the TSC counter and its rate, and the PIT's interrupt */
void	clockinit(void);
uvlong	fastticks(uvlong*);
void	timerset(uvlong);
void	kmapinval(void);

/* main.c: start a new kernel process at p->sched */
void	kprocchild(Proc*, void(*)(void*), void*);

/* main.c: per-process floating point.  Nothing uses x87 state yet. */
void	procsave(Proc*);
void	procrestore(Proc*);
void	fpinit(void);
void	fpoff(void);

/* arch.c: the scheduler's idle wait, and one-core wakeups */
void	idlehands(void);
void	idlewake(void);
void	setpanic(void);
void	clockcheck(void);

/* main.c: the clock's contribution to the scheduler */
void	hzclock(Ureg*);

#define	getcallerpc(x)	((ulong)(uintptr)__builtin_return_address(0))

/*
 * waserror: see ../arm64/fns.h.  errlabcheck() catches an error stack
 * about to overflow before setlabel writes past it.
 */
#define	waserror()	(errlabcheck(), up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#include "../port/portfns.h"

#endif
