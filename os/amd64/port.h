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
void	shelltest(void);
void	nettest(void);
void	pcitest(void);
void	jittest(void);
void	interptest(void);

/* the 8259 line registry (trap.c) */
int	intrenable(int, void (*)(void*), void*, char*);
void	intrdisable(int);

/* the console's receive poller (consinputinit, os/amd64/consinput.c) */
void	consinputinit(void);

/* the media a kernel configuration opts into (os/ip) */
void	loopbackmediumlink(void);
void	ethermediumlink(void);

/* the virtio-net PCI driver (os/amd64/virtionet.c) */
void	virtionetlink(void);

/* PCI configuration space and MMIO windows (os/amd64/pci.c) */
uint32_t pcicfgr32(int, int, int, int);
void	pcicfgw32(int, int, int, int, uint32_t);
uint16_t pcicfgr16(int, int, int, int);
uint8_t	pcicfgr8(int, int, int, int);
void	pciwrite8(int, int, int, int, uint8_t);
void	pciwrite16(int, int, int, int, uint16_t);
void*	mmiomap(uint64_t, uint64_t);

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
