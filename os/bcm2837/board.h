/*
 * BCM2837-only declarations.
 *
 * These describe hardware that exists on this SoC and nowhere else --
 * the VideoCore mailbox, its firmware framebuffer, the GPIO block and
 * the 1MHz system timer. They deliberately do NOT live in
 * ../arm64/fns.h: that header is the contract every AArch64 board
 * satisfies, and a declaration there is a promise the next port has to
 * keep. Anything that would make os/virt implement a VideoCore mailbox
 * belongs here instead.
 *
 * Include after dat.h, like fns.h.
 */

/* gpio.c */
void	gpiofunc(int, int);
void	gpiopull(int, int);
void	gpioout(int, int);
int	gpioin(int);
int	gpiogetfunc(int);

/* mailbox.c */
int	mboxprop(u32int, u32int*, int, int);
int	setpower(int, int);
int	mboxfballoc(u32int, u32int, u32int, Fbinfo*);
int	mboxfbvoff(u32int, u32int);
int	mboxfbnumdisplays(void);
int	mboxfbdisplaynum(u32int);
int	mboxfbgetdim(u32int*, u32int*);

/* fb.c */
int	fbinit(Fbinfo*);
void	fbfill(Fbinfo*, u32int);
void	fbrect(Fbinfo*, int, int, int, int, u32int);
int	fbconsinit(Fbinfo*);
void	fbconsputs(char*, int);

/*
 * clock.c -- the BCM system timer, a free-running 64-bit counter at a
 * fixed 1MHz. Its rate is set by the hardware rather than reported by
 * firmware, which is what makes it usable as the reference
 * boardclockcheck() measures CNTFRQ_EL0 against.
 */
u64int	systimer(void);
void	boardreboot(void);
