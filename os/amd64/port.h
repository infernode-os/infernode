#ifndef _OS_AMD64_PORT_H_
#define _OS_AMD64_PORT_H_

#include <stdint.h>

void	portinit(uint64_t, uint64_t);
void	porttest(void);
void	proctest(void);
void	preemptest(void);

/* the allocators and the process table, ready for kproc() */
int	portprocinit(void);

/* the 8254 tick: from the trap, and its questions for it */
void	portclocktick(uint64_t);
int	portactive(void);

/* the top of the RAM the allocators may use */
extern unsigned long ramtop;

#endif
