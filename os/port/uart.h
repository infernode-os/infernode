/*
 * The serial port interface: devuart.c (#t) above, one PhysUart per
 * kind of hardware below. Inferno's os/port/uart.h, as this tree
 * carried it until e3914b1c7; the one change is the QLock, which the
 * Plan 9 dialect embedded anonymously and clang cannot (see
 * os/bcm2837/README.md "the Plan 9 C dialect is de-anonymized by hand").
 */
typedef struct PhysUart PhysUart;
typedef struct Uart Uart;

/*
 *  routines to access UART hardware
 */
struct PhysUart
{
	char*	name;
	Uart*	(*pnp)(void);
	void	(*enable)(Uart*, int);
	void	(*disable)(Uart*);
	void	(*kick)(Uart*);
	void	(*dobreak)(Uart*, int);
	int	(*baud)(Uart*, int);
	int	(*bits)(Uart*, int);
	int	(*stop)(Uart*, int);
	int	(*parity)(Uart*, int);
	void	(*modemctl)(Uart*, int);
	void	(*rts)(Uart*, int);
	void	(*dtr)(Uart*, int);
	long	(*status)(Uart*, void*, long, long);
	void	(*fifo)(Uart*, int);
	void	(*power)(Uart*, int);
	int	(*getc)(Uart*);	/* polling versions, for iprint, rdb */
	void	(*putc)(Uart*, int);
	/*
	 * Stop (1) or resume (0) taking input from the hardware. With
	 * hardware flow control on, input the stage has no room for is
	 * left in the FIFO, whose filling drops RTS; uartclock resumes
	 * once it has moved the stage on. nil: the stage overflows into
	 * berr, as it always did.
	 */
	void	(*rxhold)(Uart*, int);
};

enum {
	/*
	 * Input is staged at interrupt time and moved to the queue every
	 * 22 ms (uartclock): 3 Mbaud is 6600 bytes in that time, which a
	 * 1024-byte stage dropped most of. With rxhold
	 * nothing is dropped whatever the size; the size is what keeps
	 * the line running at its rate rather than stopping each tick.
	 */
	Stagesize=	8192
};

/*
 *  software UART
 */
struct Uart
{
	void*	regs;			/* hardware stuff */
	void*	saveregs;		/* place to put registers on power down */
	char*	name;			/* internal name */
	ulong	freq;			/* clock frequency */
	int	bits;			/* bits per character */
	int	stop;			/* stop bits */
	int	parity;			/* even, odd or no parity */
	int	baud;			/* baud rate */
	PhysUart*phys;
	int	console;		/* used as a serial console */
	int	special;		/* internal kernel device */
	Uart*	next;			/* list of allocated uarts */

	QLock	ql;			/* was anonymous: clang declares no field for it */
	int	type;			/* ?? */
	int	dev;
	int	opens;

	int	enabled;
	Uart	*elist;			/* next enabled interface */

	int	perr;			/* parity errors */
	int	ferr;			/* framing errors */
	int	oerr;			/* rcvr overruns */
	int	berr;			/* no input buffers */
	int	serr;			/* input queue overflow */
	ulong	nstaged;		/* bytes moved istage -> iq by uartclock */
	ulong	nread;			/* bytes handed to readers */
	ulong	nclock;			/* uartclock visits while enabled */

	/* buffers */
	int	(*putc)(Queue*, int);
	Queue	*iq;
	Queue	*oq;

	Lock	rlock;
	uchar	istage[Stagesize];
	uchar	*iw;
	uchar	*ir;
	uchar	*ie;

	Lock	tlock;			/* transmit */
	uchar	ostage[Stagesize];
	uchar	*op;
	uchar	*oe;
	int	drain;

	int	modem;			/* hardware flow control on */
	int	rxheld;			/* input left in the hardware: the stage is full */
	ulong	nhold;			/* times input was held */
	int	xonoff;			/* software flow control on */
	int	blocked;
	int	cts, dsr, dcd, dcdts;	/* keep track of modem status */
	int	ctsbackoff;
	int	hup_dsr, hup_dcd;	/* send hangup upstream? */
	int	dohup;

	Rendez	r;
};

/* the board's table, in pnp order: eia0 is physuart[0]'s */
extern PhysUart*	physuart[];

extern int	uartctl(Uart*, char*);
extern void	uartkick(void*);
extern void	uartrecv(Uart*, char);
extern int	uartroom(Uart*);
extern int	uartstageoutput(Uart*);
