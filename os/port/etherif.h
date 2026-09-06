/*
 * An Ethernet instance, as devether.c serves it and a link driver
 * fills it in.
 *
 * The shape is Plan 9's etherif.h (sys/src/9/port in the
 * 0intro/plan9-contrib mirror, repo-root LICENSE: Plan 9 Foundation,
 * MIT): a Netif with a driver vtable beside it, one per #lN. Written
 * rather than imported because Plan 9's embeds the Netif anonymously
 * and this tree de-anonymizes by hand (os/bcm2837/README.md says
 * why), and because instance 0 here carries a data path Plan 9 never
 * had -- USB endpoints handed over from a Limbo driver -- whose state
 * lives in the same struct.
 *
 * WHICH HALF A DRIVER USES. A kernel link driver (ether4330.c) fills
 * in ctlr, ea and the function pointers, and never touches the USB
 * fields. The USB path (instance 0) leaves the function pointers nil
 * and devether.c moves the bytes itself. devether.c decides which is
 * which by whether transmit is set, so a driver that registers is a
 * driver that has all of them.
 *
 *	attach		called in the process that binds #lN: bring the
 *			link up, or error() saying why not. Runs in the
 *			binder's namespace, which is how a driver that
 *			needs a file (firmware) finds it.
 *	transmit	frames are on oq; send them
 *	ifstat		the ifstats file: state a client can read
 *	ctl		a ctl write netif.c did not understand; return
 *			the count or error()
 *	shutdown	the machine is going down
 */

typedef struct Ether Ether;
struct Ether
{
	Netif	nif;		/* MUST be first: netif.c casts the pointer */
	int	ctlrno;		/* which #lN this is */

	/* a link driver, when there is one */
	void	*ctlr;
	uchar	ea[Eaddrlen];
	Queue	*oq;		/* outbound frames, one Block each */
	void	(*attach)(Ether*);
	void	(*transmit)(Ether*);
	long	(*ifstat)(Ether*, void*, long, ulong);
	long	(*ctl)(Ether*, void*, long);
	void	(*shutdown)(Ether*);

	/* the USB-endpoint data path: instance 0 only */
	QLock	bindlk;		/* one bind, ever */
	int	bound;
	int	family;
	long	burst;		/* how much one bulk IN may carry */
	Chan	*inchan;	/* the endpoints, held open forever */
	Chan	*outchan;
	uchar	*txbuf;
	long	ntxbuf;
	uchar	*rxbuf;
	long	nrxbuf;
	long	nacc;		/* bytes carried over between reads */

	/* rx timing: where a receive cycle's time actually goes */
	ulong	nrd;		/* reads that returned data */
	uvlong	rdns;		/* ns inside kchanio for those */
	uvlong	gapns;		/* ns between one read's end and the next's start */
	uvlong	rdbytes;	/* bytes those reads returned */
	long	rdmax;		/* largest single read */
	int	blackhole;	/* count arrivals, deliver nothing: the sink */
};

/*
 * The instance a driver registers with: fill in the vtable before
 * anyone binds #lN. nil if there is no such instance.
 */
Ether*	etherinstance(int);
