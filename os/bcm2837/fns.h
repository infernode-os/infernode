/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
void	uartputs(char*);
void	uartputx(u64int);
void	uartputd(u64int);

/* gpio.c */
void	gpiofunc(int, int);
void	gpiopull(int, int);
void	gpioout(int, int);
int	gpioin(int);
int	gpiogetfunc(int);

/* mailbox.c */
int	mboxprop(u32int, u32int*, int, int);
int	mboxfballoc(u32int, u32int, u32int, Fbinfo*);

/* fb.c */
int	fbinit(Fbinfo*);
void	fbfill(Fbinfo*, u32int);
void	fbrect(Fbinfo*, int, int, int, int, u32int);

/* clock.c */
void	clockinit(void);
u64int	clockcount(void);
u64int	clockfreq(void);
u64int	clockticks(void);
u64int	systimer(void);
void	microdelay(u64int);
int	clockintr(void);
int	irqdispatch(void);
void	intrenable(void);
void	intrdisable(void);
int	intrenabled(void);

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

/* typecheck.c */
int	typecheck(void);

/* main.c */
void	kmain(void);
