/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
void	uartputs(char*);
void	uartputx(u64int);
void	uartputd(u64int);

/* mailbox.c */
int	mboxprop(u32int, u32int*, int, int);
int	mboxfballoc(u32int, u32int, u32int, Fbinfo*);

/* fb.c */
int	fbinit(Fbinfo*);
void	fbfill(Fbinfo*, u32int);
void	fbrect(Fbinfo*, int, int, int, int, u32int);

/* mmu.c */
void	mmuinit(void);
void	mmuenable(void);
int	mmuon(void);
int	mmucaches(void);
uintptr	mmuramtop(void);
uintptr	mmul1(void);
uintptr	mmumapped(void);
u64int	mmutcr(void);
u64int	mmumair(void);

/* trap.c */
void	trap(Ureg*);
void	dumpureg(Ureg*);
void	panic(char*);

/* vectors.S */
void	trapinit(void);

/* main.c */
void	kmain(void);
