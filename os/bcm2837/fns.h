/*
 * Prototypes for the bare-metal kernel.  Include after dat.h.
 */

/* uart.c */
void	uartinit(void);
void	uartputc(int);
void	uartputs(char*);
void	uartputx(u64int);
void	uartputd(u64int);

/* trap.c */
void	trap(Ureg*);
void	dumpureg(Ureg*);
void	panic(char*);

/* vectors.S */
void	trapinit(void);

/* main.c */
void	kmain(void);
