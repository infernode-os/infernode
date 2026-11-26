#ifndef _OS_AMD64_PORT_H_
#define _OS_AMD64_PORT_H_

#include <stdint.h>

void	portinit(uint64_t, uint64_t);
void	porttest(void);
void	proctest(void);
void	preemptest(void);
void	clocktest(void);
void	qiotest(void);
void	fmttest(void);
void	chantest(void);
void	ringdevtest(void);
void	mounttest(void);
void	vmtest(void);

/* the allocators and the process table, ready for kproc() */
int	portprocinit(void);

/* the 8254 tick: from the trap, and its questions for it */
void	portclocktick(uint64_t);
int	portactive(void);

/* the top of the RAM the allocators may use */
extern unsigned long ramtop;

/* the machine's timer tick count (trap.c) */
uint64_t tickcount(void);

#endif
