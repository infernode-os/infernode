#ifndef _OS_AMD64_PORT_H_
#define _OS_AMD64_PORT_H_

#include <stdint.h>

void	portinit(uint64_t, uint64_t);
void	porttest(void);
void	proctest(void);

/* the top of the RAM the allocators may use */
extern unsigned long ramtop;

#endif
