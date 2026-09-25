/*
 * What the Broadcom family's drivers and the boards built on them share.
 *
 * These describe hardware a Raspberry Pi has and other machines do not
 * -- the VideoCore mailbox, its firmware framebuffer, the GPIO block,
 * DMA, the two SD controllers, the 1MHz system timer -- together with
 * the handful of things those drivers ask of whichever board they are
 * built into (boardfb, boardwatchdogpoll...). They deliberately do NOT
 * live in ../arm64/fns.h: that header is the contract every AArch64
 * board satisfies, and a declaration there is a promise the next port
 * has to keep. Anything that would make os/virt implement a VideoCore
 * mailbox belongs here instead.
 *
 * This was os/bcm/bcm.h, whole, until a second SoC of the family
 * (os/bcm2711) needed every line of it. A board's board.h includes it.
 *
 * Include after dat.h, like fns.h.
 */

/* uartmini.c: the polled mini-UART, for uart.c's console */
ulong	miniconsinit(void);
void	miniputc(int);
int	minigetc(void);
int	minitxidle(void);

/* uart.c: console policy over it */
int	consuartputc(Queue*, int);

/* gpio.c */
void	gpiofunc(int, int);
void	gpiopull(int, int);
void	gpioout(int, int);
int	gpioin(int);
int	gpiogetfunc(int);
void	gpioedge(int, int, int);
u32int	gpioevents(int);
void	gpioclaim(int, char*);
int	dmaenable(int, void (*)(void*), void*, char*);
void	dmastart(int, void*);
void	dmastop(int);
void	dmadisable(int);
int	dmaactive(int);
u32int	dmawhere(int);
char*	gpioclaimed(int);

/* mailbox.c */
enum
{
	Mboxcmdlinemax	= 1024,	/* the GET_COMMAND_LINE value buffer, in bytes */
};
int	mboxprop(u32int, u32int*, int, int);
u32int	mboxsetclockrate(u32int, u32int);
void	boardclock(void);
u32int	mboxresp(void);
int	mboxprop1(u32int, u32int*, int, int, u32int*);
int	setpower(int, int);
int	mboxfballoc(u32int, u32int, u32int, u32int, Fbinfo*);
int	mboxfbnumdisplays(void);
u32int	mboxclockrate(u32int);
u32int	mboxmaxclockrate(u32int);
int	mboxsetgpio(u32int, int);
int	mboxgetgpio(u32int);
u32int	mboxlastcode(void);
int	mboxgpioconfig(u32int, int*, int*);
void	mboxlockon(void);
int	mboxedid(u32int, uchar*);
int	mboxcmdline(char*, int);
int	mboxreboot(int);

/*
 * board.c: the boot watchdog's reload. The tick is core 0's clockintr;
 * the poll is microdelay's, for the boot path before interrupts run.
 */
void	boardwatchdogtick(void);
void	boardwatchdogpoll(void);

/*
 * The SD card, in two layers.
 *
 * sdmmc.c speaks the card's protocol -- identification, the CSD, block
 * reads and writes -- and knows nothing about registers. A controller
 * is an SDio: the handful of operations the card layer needs from
 * whatever piece of silicon is wired to the card's pins. There are two
 * on this SoC, sdhost.c and emmc.c, and the layer between them is what
 * lets the card move from one to the other without the card protocol
 * being written twice.
 *
 * Responses come back in the RAW layout, resp[3] = bits 127:96 down to
 * resp[0] = bits 31:0, whichever controller produced them. SDHOST stores
 * them that way; the Arasan backend shifts its own into that form.
 */
#include "../port/sdio.h"	/* the SDio interface and its flags */

extern SDio sdhostio;		/* sdhost.c */
extern SDio emmcio;		/* emmc.c */
extern SDio emmc2io;		/* os/bcm2711/emmc2.c: a second instance of emmc.c, for EMMC2 */
extern int sdarasantaken;	/* sdmmc.c: the card is on the Arasan; the radio must keep off */

/* sdmmc.c: the card, as blocks -- devsd.c's contract */
int	emmcinit(void);
int	sdblkread(uvlong, void*);
int	sdblkwrite(uvlong, void*);
int	sdblkpresent(void);
uvlong	sdblknblocks(void);
char*	sdcontroller(void);
void	boarddevprobe(void);

/*
 * ether4330.c: the CYW43455 radio on the Arasan. Probed at board init
 * after the card has left that controller; registers as #l1 whether
 * or not a radio was found, so the bind says why when there is none.
 */
void	ether4330probe(void);

/*
 * soc.c, in each board's directory: the devices one SoC of the family
 * has and the others do not. boarddevprobe calls it last.
 */
void	socdevprobe(void);
void	socusblink(void);	/* and its USB host controllers, after the DWC OTG */
int	mboxfbvoff(u32int, u32int);
int	mboxfbgetvoff(void);

/* fb.c */
int	fbinit(Fbinfo*);
int	fbinitdisp(u32int, Fbinfo*);
void	fbfill(Fbinfo*, u32int);
int	fbdisplay(u32int);		/* fb.c: fbcons's two questions, over the mailbox */
int	fbvoffset(u32int, u32int);
void	fbrect(Fbinfo*, int, int, int, int, u32int);
int	fbconsinit(Fbinfo*);
int	fbconsadd(Fbinfo*);
int	fbconsscreens(void);
int	fbconsreleased(void);
int	fbconsvoff(void);
void	fbconsstop(void);

/*
 * The software cursor, in screen.c. devpointer moves it; devdraw takes
 * it off the screen around its drawing.
 */
void	swcursorat(int, int);
void	screendumpkey(void);
void	screenhexkey(void);
void	swcursorhide(void);
void	swcursorshow(void);
Fbinfo*	boardfb(void);
int	mboxfbdispnum(u32int);
void	fbconsputs(char*, int);

/*
 * clock.c -- the BCM system timer, a free-running 64-bit counter at a
 * fixed 1MHz. Its rate is set by the hardware rather than reported by
 * firmware, which is what makes it usable as the reference
 * boardclockcheck() measures CNTFRQ_EL0 against.
 */
u64int	systimer(void);
void	boardreboot(void);
int	bcmintrprobe(void);		/* board.c: a system-timer match, as a device interrupt */

/* dmamem.c: memory a device can reach */
void	dmainit(void);
void*	dmaalloc(ulong, int);		/* zeroed; below DMATOP; nil if the arena is spent */
void	dmafree(void*, ulong);
int	dmareachable(void*, ulong);	/* may this buffer be handed to a device as it is? */
