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
typedef struct SDio SDio;
struct SDio
{
	char	*name;			/* what the console calls it */
	int	(*init)(void);		/* reset and take the pins; -1 if absent */
	void	(*enable)(void);	/* power up, 400kHz identification clock */
	int	(*cmd)(int, u32int, int, u32int*);	/* index, arg, flags, resp[4] */
	void	(*bus)(int, int);	/* width (0 = keep), clock in Hz (0 = keep) */
	void	(*iosetup)(int, int, int);	/* write, block size, block count */
	int	(*io)(int, void*, int);	/* write, buffer, bytes */

	/*
	 * SDIO only, and nil on a controller that has no SDIO device:
	 * the card interrupt, DAT1 pulled low by an SDIO function that
	 * wants attention. wait = 0 asks whether it is pending and
	 * returns; wait = 1 sleeps a tick at a time until it is. Either
	 * way the latched bit is cleared on return.
	 */
	int	(*cardintr)(int);	/* wait; returns the status bits seen */
};

/* SDio.cmd flags: what kind of answer to expect, and whether data follows */
enum
{
	Rnone		= 0,
	R48		= 1,
	R48busy		= 2,		/* R1b: the card holds DAT0 low until done */
	R136		= 3,
	Rmask		= 3,
	Rnocrc		= 1<<2,		/* R3: the OCR reply carries no CRC */
	Dread		= 1<<3,		/* a block follows, card to host */
	Dwrite		= 1<<4,		/* a block follows, host to card */
};

extern SDio sdhostio;		/* sdhost.c */
extern SDio emmcio;		/* emmc.c */

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
