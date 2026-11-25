/*
 * os/amd64/fns.h -- the machine functions os/port asks for.
 *
 * This stage provides the ones the port foundation needs: labels for
 * error unwinding and the scheduler, the atomic test-and-set under the
 * kernel's spin locks, and interrupt masking.  The rest -- process
 * switch, page-table maintenance, clock -- arrive with the files that
 * use them, in the same order as ../arm64/fns.h so the call sites stay
 * diff-able against the running port.
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

#endif
