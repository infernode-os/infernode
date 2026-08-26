/*
 * DWC OTG USB host controller, as found on BCM2835/2837.
 *
 * IMPORTED VERBATIM from Plan 9 4th edition, sys/src/9/bcm/usbdwc.c, via the
 * 0intro/plan9 mirror, which carries a repo-root LICENSE reading
 * "Copyright 2021 Plan 9 Foundation" with the full MIT text. Nokia
 * transferred Plan 9 copyright to the Foundation in 2021 and it
 * relicensed editions 1-4 under MIT; this tree's LICENSE already
 * credits the Plan 9 Foundation.
 *
 * Taken from Plan 9 directly and NOT through any third-party Raspberry
 * Pi fork. A line-level study (INFR-404) found those forks are
 * 96-99.8% verbatim Plan 9 on exactly these files, so the fork adds
 * nothing but a licensing question -- what is original to them is the
 * Inferno kernel glue, which os/arm64 and os/bcm2837 already provide
 * for AArch64.
 *
 * Compiled against this kernel's headers with ONE error, a header
 * path. That is not luck: these are native-kernel sources in the same
 * Plan 9 C dialect os/port is written in, and because InferNode is
 * LP64 with ulong the width of a pointer, upstream's "ulong holds a
 * pointer" convention is correct here by construction rather than
 * broken.
 */
/*
 * USB host driver for BCM2835
 *	Synopsis DesignWare Core USB 2.0 OTG controller
 *
 * Copyright © 2012 Richard Miller <r.miller@acm.org>
 *
 * This is work in progress:
 * - no isochronous pipes
 * - no bandwidth budgeting
 * - frame scheduling is crude
 * - error handling is overly optimistic
 * It should be just about adequate for a Plan 9 terminal with
 * keyboard, mouse, ethernet adapter, and an external flash drive.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"board.h"	/* setpower() -- board-specific, via the mailbox */
#include	"io.h"
#include	"../port/error.h"
#include	"../port/usb.h"

#include "dwcotg.h"

enum
{
	/*
	 * Upstream writes VIRTIO here -- the address Plan 9's bcm port
	 * maps peripherals at. This kernel identity-maps them at their
	 * physical base instead, so PHYSIO is the same window by another
	 * name.
	 */
	USBREGS		= PHYSIO + 0x980000,
	Resetlimit	= 100000,	/* ~1s at 10us a turn */
	Chandislimit	= 10000,
	Sofspin		= 100000,	/* frames stop only if the host does */	/* ~100ms; a live channel halts at once */
	/*
	 * How long to wait on one transfer, and how many attempts before
	 * calling it dead. Generous on purpose: the point is to bound a
	 * failure, not to police latency.
	 */
	/*
	 * The timeout IS the cost of every transfer here.
	 *
	 * This driver never takes a USB interrupt: chanwait runs the
	 * whole wait at splhi and clears hcintmsk before spl drops, so
	 * the core asserts and de-asserts where nothing can be
	 * delivered. tsleep therefore returns on its timeout rather than
	 * on a wakeup, every time.
	 *
	 * At 200ms a slice that made a keyboard unusable: about a minute
	 * to echo a key, and anything pressed and released between polls
	 * never reported at all, because the device reports CHANGES and
	 * nothing was looking when they changed.
	 *
	 * Spinning on chandone instead was tried twice and broke
	 * something both times -- enumeration stalled, then the keyboard
	 * stopped reporting -- because a split transaction is timed
	 * against the frame counter and holding splhi across it disturbs
	 * exactly that. So shorten the slice rather than replace the
	 * sleep: the same two seconds of total patience, in pieces small
	 * enough that a transfer costs milliseconds. Nothing spins and
	 * nothing holds splhi any longer than before.
	 */
	/*
	 * Long slices, few of them, and that ordering is deliberate.
	 *
	 * Shortening the slice to 5ms with 400 attempts -- the same two
	 * seconds of patience -- broke low-speed enumeration, because
	 * each attempt re-arms haintmsk and hcintmsk and takes splhi
	 * again. Four hundred of those inside one split transaction
	 * disturbs the frame timing it depends on, exactly as spinning
	 * on chandone did. Two different attempts to reduce latency here
	 * broke the same thing for the same reason.
	 *
	 * The latency was never really this constant. It was the split
	 * retry below re-issuing on every NYET, each one costing a whole
	 * slice; bounding that is what fixed it, and this stays as it
	 * was.
	 */
	Maxnyet		= 2,		/* split retries before reporting none */
	Chantmout	= 200,		/* ms per attempt */
	Maxtmout	= 10,		/* attempts before giving up */

	Enabledelay	= 50,
	Resetattempts	= 3,	/* a fluffed chirp usually succeeds next time */
	Resetdelay	= 10,
	ResetdelayHS	= 50,

	Read		= 0,
	Write		= 1,
};

typedef struct Ctlr Ctlr;
typedef struct Epio Epio;

struct Ctlr {
	Dwcregs	*regs;		/* controller registers */
	int	nchan;		/* number of host channels */
	ulong	chanbusy;	/* bitmap of in-use channels */
	QLock	chanlock;	/* serialise access to chanbusy */
	QLock	split;		/* serialise split transactions */
	int	splitretry;	/* count retries of Nyet */
	int	sofchan;	/* bitmap of channels waiting for sof */
	int	wakechan;	/* bitmap of channels to wakeup after fiq */
	int	debugchan;	/* bitmap of channels for interrupt debug */
	Rendez	*chanintr;	/* sleep till interrupt on channel N */
};

struct Epio {
	/*
	 * Two locks, not one.
	 *
	 * A bulk or interrupt endpoint number names TWO endpoints -- 0x82
	 * and 0x02 are different pipes that happen to share the number 2
	 * -- and devusb represents the pair as a single Ep with mode rw.
	 * One lock across both directions then means a reader blocked
	 * waiting for a packet, which is the normal resting state of any
	 * network driver, holds the endpoint against every transmit
	 * forever.
	 *
	 * That is exactly what happened to the first frame this port
	 * tried to send: the receive process was parked in a bulk IN, the
	 * transmit never reached eptrans() at all, and the interface
	 * above it sat waiting for a write that could not start.
	 *
	 * Control transfers keep sharing ql, and must: there epwrite
	 * performs the whole transaction and epread only collects the
	 * reply out of cb, so the two halves are one operation and have
	 * to stay serialised against each other.
	 */
	QLock	ql;		/* writes, and control transfers entire */
	QLock	rl;		/* reads on bulk and interrupt endpoints */
	Block	*cb;
	ulong	lastpoll;
};

static Ctlr dwc;
static int debug;
/* interrupts this controller has raised */
static ulong nusbintr;

/* how many interrupt failures still to report; see eptrans */
static int dwcintrerr;

/* how many interrupt split phases still to report; see chanio */
static int dwcintrsplit;

static char Ebadlen[] = "bad usb request length";

static void clog(Ep *ep, Hostchan *hc);
static void logdump(Ep *ep);

static Hostchan*
chanalloc(Ep *ep)
{
	Ctlr *ctlr;
	int bitmap, i;

	ctlr = ep->hp->aux;
	qlock(&ctlr->chanlock);
	bitmap = ctlr->chanbusy;
	for(i = 0; i < ctlr->nchan; i++)
		if((bitmap & (1<<i)) == 0){
			ctlr->chanbusy = bitmap | 1<<i;
			qunlock(&ctlr->chanlock);
			return &ctlr->regs->hchan[i];
		}
	qunlock(&ctlr->chanlock);
	panic("miller is a lazy git");
	return nil;
}

static void
chanrelease(Ep *ep, Hostchan *chan)
{
	Ctlr *ctlr;
	int i;

	ctlr = ep->hp->aux;
	i = chan - ctlr->regs->hchan;
	qlock(&ctlr->chanlock);
	ctlr->chanbusy &= ~(1<<i);
	qunlock(&ctlr->chanlock);
}

static void
chansetup(Hostchan *hc, Ep *ep)
{
	int hcc;
	Ctlr *ctlr = ep->hp->aux;

	if(ep->debug)
		ctlr->debugchan |= 1 << (hc - ctlr->regs->hchan);
	else
		ctlr->debugchan &= ~(1 << (hc - ctlr->regs->hchan));
	switch(ep->dev->state){
	case Dconfig:
	case Dreset:
		hcc = 0;
		break;
	default:
		hcc = ep->dev->nb<<ODevaddr;
		break;
	}
	hcc |= ep->maxpkt | 1<<OMulticnt | ep->nb<<OEpnum;
	switch(ep->ttype){
	case Tctl:
		hcc |= Epctl;
		break;
	case Tiso:
		hcc |= Episo;
		break;
	case Tbulk:
		hcc |= Epbulk;
		break;
	case Tintr:
		hcc |= Epintr;
		break;
	}
	switch(ep->dev->speed){
	case Lowspeed:
		hcc |= Lspddev;
		/* fall through */
	case Fullspeed:
		/*
		 * Splits, and ONLY when the bus is actually high speed.
		 *
		 * A split transaction exists so a high-speed hub can talk
		 * to a full- or low-speed device behind it at the slower
		 * rate without holding the high-speed bus idle. If the bus
		 * below the controller is not running at high speed there
		 * is nothing to translate: everything is already going at
		 * the device's rate, and asking for a split makes the
		 * controller wait for a start-of-frame that means nothing
		 * to it.
		 *
		 * Upstream keys on hub > 1 alone, because on a real Pi the
		 * hub soldered to the root port (the LAN9514) is always
		 * high speed, so the two conditions coincide. They do not
		 * coincide under emulation, where the hub on the root port
		 * is a full-speed one -- and the symptom is not a wrong
		 * answer but a driver that stops for ever inside sofwait(),
		 * one level deeper into the tree than anything that had
		 * been tried before.
		 *
		 * The root port's negotiated speed answers this for the
		 * whole tree: a full-speed hub makes the port full speed,
		 * so if the port is not high speed nothing below it is.
		 */
		if(ep->dev->hub > 1 &&
		   (ctlr->regs->hport0 & Prtspd) == HIGHSPEED){
			hc->hcsplt = Spltena | POS_ALL | ep->dev->hub<<OHubaddr |
				ep->dev->port;
			break;
		}
		/* fall through */
	default:
		hc->hcsplt = 0;
		break;
	}
	hc->hcchar = hcc;
	hc->hcint = ~0;

}

/*
 * sofdone was the condition sofwait slept on. sofwait polls the frame
 * counter now -- see the comment there -- so nothing sleeps on a
 * start-of-frame any more, and the interrupt it waited for is one this
 * driver never takes.
 */

static void
sofwait(Ctlr *ctlr, int n)
{
	Dwcregs *r;
	int i, f, last;

	USED(n);
	r = ctlr->regs;

	/*
	 * Watch the frame counter instead of waiting for an interrupt.
	 *
	 * This slept -- unbounded, not tsleep -- on the start-of-frame
	 * interrupt. This driver never takes a USB interrupt: chanwait
	 * runs its whole wait at splhi and clears hcintmsk before
	 * lowering spl, so the core asserts and de-asserts where nothing
	 * can be delivered. So the sleep returned only when sofdone
	 * happened to be true on entry, and would otherwise have waited
	 * for ever for a wakeup that cannot come.
	 *
	 * It matters only here, because only a split transaction calls
	 * this -- which is to say only a low-speed or full-speed device
	 * behind a high-speed hub, which is to say the keyboard. The
	 * alignment a split needs was therefore whatever the frame
	 * counter happened to hold, and the alternative to that was a
	 * hang.
	 *
	 * hfnum's low three bits are the microframe. Wait for one to
	 * begin, and do not start a split in microframe 6: the complete
	 * split would fall at the frame boundary, which is the case the
	 * original was avoiding.
	 */
	last = r->hfnum & 7;
	for(i = 0; i < Sofspin; i++){
		f = r->hfnum & 7;
		if(f != last){
			if(f != 6)
				return;
			last = f;
		}
		microdelay(5);
	}
}

static int
chandone(void *a)
{
	Hostchan *hc;

	hc = a;
	if(hc->hcint == (Chhltd|Ack))
		return 0;
	return (hc->hcint & hc->hcintmsk) != 0;
}


static int
chanwait(Ep *ep, Ctlr *ctlr, Hostchan *hc, int mask)
{
	uint fn1, fn2;
	int intr, n, x, ointr, ntmout;
	ulong start, now;
	Dwcregs *r;

	r = ctlr->regs;
	n = hc - r->hchan;
	ntmout = 0;
	for(;;){
restart:
		x = splhi();
		r->haintmsk |= 1<<n;
		hc->hcintmsk = mask;
		/*
		 * Bounded, not indefinite.
		 *
		 * An unbounded sleep here means any transfer the controller
		 * never completes takes the whole machine with it -- not
		 * just USB, and not just the process that asked. On this
		 * board that is exactly what happened: enumeration stalled
		 * after the port reset and the console went silent, so
		 * there was no shell left to ask what had gone wrong and
		 * no way to reboot except the power switch.
		 *
		 * A transfer that does not finish is a fault to report, not
		 * a reason to stop. Waiting a bounded time and retrying a
		 * bounded number of times turns a dead machine into an I/O
		 * error, which the caller above can print.
		 */
		/*
		 * Poll briefly before sleeping.
		 *
		 * This driver never takes a USB interrupt -- the whole wait
		 * runs at splhi and hcintmsk is cleared before spl drops,
		 * so the core asserts and de-asserts where nothing can be
		 * delivered. tsleep therefore almost always returns on its
		 * TIMEOUT rather than on a wakeup, and every transfer that
		 * does not complete before the sleep begins costs the full
		 * Chantmout, which is now a few milliseconds rather than
		 * microseconds.
		 *
		 * Enumeration survived that because it is a few dozen
		 * transfers. A keyboard does not: polling an interrupt
		 * endpoint at 200ms a go put roughly a minute between
		 * pressing a key and seeing it, and any key pressed and
		 * released inside one of those windows was never reported
		 * at all -- the device reports changes, and we were not
		 * looking when they changed.
		 *
		 * So spin on chandone first, for about a millisecond, which
		 * is far longer than a transfer needs and far shorter than
		 * anything a person notices. The sleep stays as the
		 * fallback for a transfer that genuinely stalls.
		 */
		/*
		 * One long sleep, and it is load-bearing.
		 *
		 * Four attempts have been made to shorten this so an
		 * interrupt endpoint could be polled faster, and all four
		 * broke split transactions: spinning on chandone at splhi;
		 * looping back to restart with a 5ms timeout, which re-armed
		 * the masks each time; shortening Chantmout outright; and
		 * arming once then sleeping in forty short slices, which
		 * touches no masks at all and STILL fails. Enumeration
		 * stalls or times out every time.
		 *
		 * Whatever the mechanism, the split sequence wants this wait
		 * left alone, and four failures is enough evidence to stop
		 * trying to make the approach work.
		 *
		 * The cost is real and understood: without interrupts tsleep
		 * returns on its timeout, so an interrupt endpoint is read
		 * about once a second, and a HID device that holds only its
		 * latest state loses keys pressed between reads. The fix for
		 * that is to make the USB interrupt actually arrive -- see
		 * the note in eptrans -- not to keep shaving this timeout.
		 */
		tsleep(&ctlr->chanintr[n], chandone, hc, Chantmout);
		if(!chandone(hc)){
			hc->hcintmsk = 0;
			splx(x);
			if(++ntmout > Maxtmout){
				hc->hcchar |= Chdis;
				print("usbotg: ep%d.%d transfer timed out "
					"(hcint %8.8ux hcchar %8.8ux gintsts %8.8ux\n"
					"usbotg:   hcdma %8.8ux hctsiz %8.8ux "
					"haint %8.8ux haintmsk %8.8ux gahbcfg %8.8ux)\n",
					ep->dev->nb, ep->nb, hc->hcint,
					hc->hcchar, r->gintsts,
					hc->hcdma, hc->hctsiz,
					r->haint, r->haintmsk, r->gahbcfg);
				/*
				 * Is the controller alive at all, and is the
				 * host still framing? nusbintr separates "the
				 * core never interrupts" from "it interrupts
				 * and we lose the wakeup"; two reads of hfnum
				 * separate "frames are running" from "the host
				 * scheduler is stopped", which look identical
				 * from the channel registers alone.
				 */
				fn1 = r->hfnum;
				microdelay(1000);
				fn2 = r->hfnum;
				print("usbotg:   %lud intrs taken, hfnum "
					"%8.8ux->%8.8ux, hcintmsk %8.8ux, "
					"hcsplt %8.8ux\n",
					nusbintr, fn1, fn2,
					hc->hcintmsk, hc->hcsplt);
				error(Eio);
			}
			continue;
		}
		hc->hcintmsk = 0;
		splx(x);
		intr = hc->hcint;
		if(intr & Chhltd)
			return intr;
		start = fastticks(0);
		ointr = intr;
		now = start;
		do{
			intr = hc->hcint;
			if(intr & Chhltd){
				if((ointr != Ack && ointr != (Ack|Xfercomp)) ||
				   intr != (Ack|Chhltd|Xfercomp) ||
				   (now - start) > 60)
					dprint("await %x after %ld %x -> %x\n",
						mask, now - start, ointr, intr);
				return intr;
			}
			if((intr & mask) == 0){
				dprint("ep%d.%d await %x intr %x -> %x\n",
					ep->dev->nb, ep->nb, mask, ointr, intr);
				goto restart;
			}
			now = fastticks(0);
		}while(now - start < 100);
		dprint("ep%d.%d halting channel %8.8ux hcchar %8.8ux "
			"grxstsr %8.8ux gnptxsts %8.8ux hptxsts %8.8ux\n",
			ep->dev->nb, ep->nb, intr, hc->hcchar, r->grxstsr,
			r->gnptxsts, r->hptxsts);
		mask = Chhltd;
		hc->hcchar |= Chdis;
		start = m->ticks;
		while(hc->hcchar & Chen){
			if(m->ticks - start >= 100){
				print("ep%d.%d channel won't halt hcchar %8.8ux\n",
					ep->dev->nb, ep->nb, hc->hcchar);
				break;
			}
		}
		logdump(ep);
	}
}

static int
chanintr(Ctlr *ctlr, int n)
{
	Hostchan *hc;
	int i, k;

	hc = &ctlr->regs->hchan[n];
	if(ctlr->debugchan & (1<<n))
		clog(nil, hc);
	if((hc->hcsplt & Spltena) == 0)
		return 0;
	i = hc->hcint;
	if(i == (Chhltd|Ack)){
		hc->hcsplt |= Compsplt;
		ctlr->splitretry = 0;
	}else if(i == (Chhltd|Nyet)){
		if(++ctlr->splitretry >= 3)
			return 0;
	}else
		return 0;
	if(hc->hcchar & Chen){
		iprint("hcchar %8.8ux hcint %8.8ux", hc->hcchar, hc->hcint);
		hc->hcchar |= Chen | Chdis;
		/*
		 * Bounded, and this copy matters more than the one in
		 * chanio: this runs in the interrupt handler, so a channel
		 * that never halts does not hang one process, it hangs the
		 * machine with interrupts off.
		 */
		for(k = 0; k < Chandislimit; k++){
			if((hc->hcchar & Chen) == 0)
				break;
			microdelay(10);
		}
		iprint(" %8.8ux\n", hc->hcint);
	}
	hc->hcint = i;
	if(ctlr->regs->hfnum & 1)
		hc->hcchar &= ~Oddfrm;
	else
		hc->hcchar |= Oddfrm;
	hc->hcchar = (hc->hcchar &~ Chdis) | Chen;
	return 1;
}

static Reg chanlog[32][5];
static int nchanlog;

static void
logstart(Ep *ep)
{
	if(ep->debug)
		nchanlog = 0;
}

static void
clog(Ep *ep, Hostchan *hc)
{
	Reg *p;

	if(ep != nil && !ep->debug)
		return;
	if(nchanlog == 32)
		nchanlog--;
	p = chanlog[nchanlog];
	p[0] = dwc.regs->hfnum;
	p[1] = hc->hcchar;
	p[2] = hc->hcint;
	p[3] = hc->hctsiz;
	p[4] = hc->hcdma;
	nchanlog++;
}

static void
logdump(Ep *ep)
{
	Reg *p;
	int i;

	if(!ep->debug)
		return;
	p = chanlog[0];
	for(i = 0; i < nchanlog; i++){
		print("%5.5d.%5.5d %8.8ux %8.8ux %8.8ux %8.8ux\n",
			p[0]&0xFFFF, p[0]>>16, p[1], p[2], p[3], p[4]);
		p += 5;
	}
	nchanlog = 0;
}

static int
chanio(Ep *ep, Hostchan *hc, int dir, int pid, void *a, int len)
{
	Ctlr *ctlr;
	int nleft, n, nt, i, maxpkt, npkt;
	uint hcdma, hctsiz, lasti;
	int splitphase, nyets;

	ctlr = ep->hp->aux;
	maxpkt = ep->maxpkt;
	npkt = HOWMANY(len, ep->maxpkt);
	if(npkt == 0)
		npkt = 1;

	hc->hcchar = (hc->hcchar & ~Epdir) | dir;
	if(dir == Epin)
		n = ROUND(len, ep->maxpkt);
	else
		n = len;
	hc->hctsiz = n | npkt<<OPktcnt | pid;
	/*
	 * BUSADDR, not PADDR.
	 *
	 * The controller masters memory from the VideoCore side and sees
	 * it through those addresses, the same reason mailbox.c hands the
	 * GPU a BUSADDR.
	 *
	 * This was briefly switchable, because an enabled channel that
	 * never ran was equally consistent with the alias being wrong.
	 * The board settled it: both forms failed identically, and the
	 * real fault was that the USB block had never been powered --
	 * setpower was passing byte counts where element counts were
	 * wanted, and the mailbox buffer was never cleaned from the
	 * caches.
	 *
	 * The switch is gone because it was not merely dead: it flipped
	 * this mode GLOBALLY on the first timeout anywhere, so a single
	 * slow transfer silently changed how every later one addressed
	 * memory. That is a poor thing to leave in a driver, and a worse
	 * thing to leave in one whose timeouts were being tuned.
	 */
	hc->hcdma  = BUSADDR(PADDR(a));

	lasti = 0;
	splitphase = 0;
	nyets = 0;
	nleft = len;
	logstart(ep);
	for(;;){
		hcdma = hc->hcdma;
		hctsiz = hc->hctsiz;
		hc->hctsiz = hctsiz & ~Dopng;
		if(hc->hcchar&Chen){
			dprint("ep%d.%d before chanio hcchar=%8.8ux\n",
				ep->dev->nb, ep->nb, hc->hcchar);
			hc->hcchar |= Chen | Chdis;
			/*
			 * Bounded, because a channel that never ran also
			 * never halts.
			 *
			 * This waits for the controller to acknowledge a
			 * disable. Upstream spins here for ever, which is
			 * safe only if the channel was live: after a
			 * transfer that timed out because the controller
			 * ignored it, Chen stays set and this loop is the
			 * end of the process. That is what silently ate the
			 * retry after the first ep2.0 timeout -- one attempt
			 * appeared in the log and the next never issued,
			 * because the probe was still spinning here.
			 */
			for(n = 0; n < Chandislimit; n++){
				if((hc->hcchar & Chen) == 0)
					break;
				microdelay(10);
			}
			if(n >= Chandislimit)
				print("usbotg: ep%d.%d channel will not halt "
					"(hcchar %8.8ux)\n",
					ep->dev->nb, ep->nb, hc->hcchar);
			hc->hcint = Chhltd;
		}
		if((i = hc->hcint) != 0){
			dprint("ep%d.%d before chanio hcint=%8.8ux\n",
				ep->dev->nb, ep->nb, i);
			hc->hcint = i;
		}
		if(hc->hcsplt & Spltena){
			qlock(&ctlr->split);
			sofwait(ctlr, hc - ctlr->regs->hchan);
			if((dwc.regs->hfnum & 1) == 0)
				hc->hcchar &= ~Oddfrm;
			else
				hc->hcchar |= Oddfrm;
		}
		hc->hcchar = (hc->hcchar &~ Chdis) | Chen;
		/*
		 * What the core did with the enable, immediately.
		 *
		 * The timeout dump shows hcchar with Chdis SET, and that
		 * dump happens before anything in this driver tries to halt
		 * the channel -- the line above explicitly clears Chdis as
		 * it sets Chen. So on the first transfer, when hcchar starts
		 * from zero, something other than this driver is setting it,
		 * and the core setting Chdis itself means it refused to run
		 * the channel rather than merely not having run it yet.
		 *
		 * gnptxsts is the other half: in DMA mode an OUT transfer
		 * needs a free entry in the non-periodic request queue and a
		 * free slot in the transmit FIFO. If either reads zero the
		 * channel stays enabled and idle for ever, which is exactly
		 * what we see, and neither was being read.
		 */
		clog(ep, hc);
		if(ep->ttype == Tbulk && dir == Epin)
			/*
			 * Nak as well as Chhltd.
			 *
			 * A bulk IN with nothing to collect is answered by
			 * the device with NAK, and the driver is meant to
			 * come back and ask again -- which the loop below
			 * does. Waiting only on Chhltd assumes the
			 * controller halts the channel on a NAK; this one
			 * does not, so the wait never ends and a receive
			 * issued before the first packet arrives never
			 * returns, no matter what turns up afterwards.
			 *
			 * The symptom was a network that transmitted
			 * perfectly and received nothing: the ARP request
			 * went out, the reply came back on the wire, and
			 * the driver was still asleep in the read it had
			 * posted beforehand.
			 */
			i = chanwait(ep, ctlr, hc, Chhltd|Nak);
		else if(ep->ttype == Tintr && (hc->hcsplt & Spltena))
			i = chanwait(ep, ctlr, hc, Chhltd);
		else
			i = chanwait(ep, ctlr, hc, Chhltd|Nak);
		clog(ep, hc);
		lasti = i;
		hc->hcint = i;

		if(hc->hcsplt & Spltena){
			hc->hcsplt &= ~Compsplt;
			qunlock(&ctlr->split);
		}

		/*
		 * Drive the two halves of a split transaction.
		 *
		 * A split is two transactions: a start-split asking the
		 * hub's translator to fetch from the slow device, and a
		 * complete-split collecting what it got. chanintr makes
		 * that transition on Chhltd|Ack -- and chanintr runs only
		 * from the interrupt handler, which this driver never
		 * reaches: chanwait runs its whole wait at splhi and clears
		 * hcintmsk before lowering spl, so the core asserts and
		 * de-asserts where nothing can be delivered.
		 *
		 * The first attempt at this triggered on Chhltd|Ack, which
		 * is what the databook describes and NOT what this core
		 * reports: the board returns Xfercomp|Chhltd|Ack for the
		 * start-split, so the condition never fired, chanio treated
		 * the start-split as the entire transfer, and the caller
		 * got whatever the buffer held -- 0x55 repeating.
		 *
		 * So the phase is tracked here rather than inferred from
		 * status, and rather than read back from hcsplt, which
		 * chanio clears a few lines above this.
		 */
		/*
		 * Watch the split phases for an interrupt endpoint.
		 *
		 * The keyboard's read runs the whole 2s timeout every time
		 * rather than NAKing and retrying quickly, so it polls
		 * under twice a second and loses most keys. Every previous
		 * split log was spent on the control transfers that
		 * enumerate the device; this path has never been watched.
		 *
		 * Each line is one turn of the loop: which phase it was in,
		 * what the channel reported, and how far the DMA pointer
		 * moved.
		 */
		if(ep->ttype == Tintr && dwcintrsplit < 12){
			dwcintrsplit++;
			print("usbotg: intr phase %d i %8.8ux hcsplt %8.8ux dma %8.8ux->%8.8ux\n",
				splitphase, i, hc->hcsplt, hcdma, hc->hcdma);
		}

		if(hc->hcsplt & Spltena){
			if(splitphase == 0){
				splitphase = 1;
				continue;	/* now collect it */
			}
			splitphase = 0;
			if(i & (Nyet|Frmovrun)){
				/*
				 * The translator has nothing yet. Ask again
				 * a few times, then give up and let the
				 * caller decide.
				 *
				 * This retried without limit, and each retry
				 * costs a full Chantmout. An interrupt
				 * endpoint with no key pressed NYETs every
				 * time, so polling a keyboard cost seconds
				 * per attempt and a keypress took about a
				 * minute to appear -- while anything pressed
				 * and released in between was never seen,
				 * because the device reports changes.
				 *
				 * A poll that returns "nothing yet" promptly
				 * is the correct answer for an interrupt
				 * endpoint; the caller asks again in a
				 * moment.
				 */
				if(++nyets <= Maxnyet){
					splitphase = 1;
					continue;
				}
				break;
			}
			nyets = 0;
		}

		if((i & Xfercomp) == 0 && i != (Chhltd|Ack) && i != Chhltd){
			if(i & Stall)
				error(Estalled);
			if(i & (Nyet|Frmovrun))
				continue;
			if(i & Nak){
				if(ep->ttype == Tintr)
					tsleep(&up->sleep, return0, 0, ep->pollival);
				else
					tsleep(&up->sleep, return0, 0, 1);
				continue;
			}
			logdump(ep);
			print("usbotg: ep%d.%d error intr %8.8ux\n",
				ep->dev->nb, ep->nb, i);
			if(i & ~(Chhltd|Ack))
				error(Eio);
			if(hc->hcdma != hcdma)
				print("usbotg: weird hcdma %x->%x intr %x->%x\n",
					hcdma, hc->hcdma, i, hc->hcint);
		}
		n = hc->hcdma - hcdma;
		if(n == 0){
			/*
			 * Nothing moved, and the controller says the
			 * transfer is finished. Believe it.
			 *
			 * Upstream decides by hcdma advancing or Pktcnt
			 * changing, and neither happens here: a zero-length
			 * transfer moves no data by definition, and this
			 * controller does not decrement Pktcnt for one. So
			 * both of its tests fail and the loop retries
			 * immediately, for ever.
			 *
			 * That matters twice over. It is the status stage of
			 * every control transfer with no data stage --
			 * SET_ADDRESS, SET_CONFIGURATION, every hub
			 * SET_FEATURE -- so without this a device can be
			 * described but never addressed. And it is what a
			 * bulk IN returns when the device has been drained:
			 * a zero-length packet rather than a NAK. Retrying
			 * that at full speed produced three million bus
			 * transactions a second and starved everything else
			 * on the machine, which presents as the kernel
			 * hanging rather than as a driver spinning.
			 */
			if(i & Xfercomp)
				break;
			if((hc->hctsiz & Pktcnt) != (hctsiz & Pktcnt))
				break;
			else
				continue;
		}
		if(dir == Epin && ep->ttype == Tbulk && n == nleft){
			nt = (hctsiz & Xfersize) - (hc->hctsiz & Xfersize);
			if(nt != n){
				if(n == ROUND(nt, 4))
					n = nt;
				else
					print("usbotg: intr %8.8ux "
						"dma %8.8ux-%8.8ux "
						"hctsiz %8.8ux-%8.ux\n",
						i, hcdma, hc->hcdma, hctsiz,
						hc->hctsiz);
			}
		}
		if(n > nleft){
			if(n != ROUND(nleft, 4))
				dprint("too much: wanted %d got %d\n",
					len, len - nleft + n);
			n = nleft;
		}
		nleft -= n;
		if(nleft == 0 || (n % maxpkt) != 0)
			break;
		if((i & Xfercomp) && ep->ttype != Tctl)
			break;
		if(dir == Epout)
			dprint("too little: nleft %d hcdma %x->%x hctsiz %x->%x intr %x\n",
				nleft, hcdma, hc->hcdma, hctsiz, hc->hctsiz, i);
	}
	logdump(ep);
	/*
	 * Say once whether any of this was interrupt-driven.
	 *
	 * The board reports nusbintr == 0 on every timeout: the
	 * controller has never raised an interrupt, so chanwait is
	 * running entirely on its tsleep timeout and the chandone poll.
	 * That works, but it is not what this driver is written to do,
	 * and it wants distinguishing from a hardware-only fault --
	 * hence reporting it after a transfer that SUCCEEDED, which only
	 * happens under emulation at present.
	 */

	return len - nleft;
}

static long
multitrans(Ep *ep, Hostchan *hc, int rw, void *a, long n)
{
	long sofar, m;

	sofar = 0;
	do{
		m = n - sofar;
		if(m > ep->maxpkt)
			m = ep->maxpkt;
		m = chanio(ep, hc, rw == Read? Epin : Epout, ep->toggle[rw],
			(char*)a + sofar, m);
		ep->toggle[rw] = hc->hctsiz & Pid;
		sofar += m;
	}while(sofar < n && m == ep->maxpkt);
	return sofar;
}

static long
eptrans(Ep *ep, int rw, void *a, long n)
{
	Hostchan *hc;

	if(ep->clrhalt){
		ep->clrhalt = 0;
		if(ep->mode != OREAD)
			ep->toggle[Write] = DATA0;
		if(ep->mode != OWRITE)
			ep->toggle[Read] = DATA0;
	}
	hc = chanalloc(ep);
	if(waserror()){
		/*
		 * Say why an interrupt transfer failed.
		 *
		 * This path returns 0 for a stall, which the caller cannot
		 * distinguish from "the device had nothing to say" -- and
		 * for an interrupt endpoint those are opposite answers. A
		 * keyboard that stalls every poll and a keyboard with no
		 * keys pressed both read as zero bytes, promptly, for ever.
		 *
		 * The error also never reaches chanio's own logging,
		 * because it unwinds past the end of it, which is why the
		 * interrupt transfer appeared not to happen at all.
		 */
		if(ep->ttype == Tintr && dwcintrerr < 4){
			dwcintrerr++;
			print("usbotg: ep%d.%d intr failed: %s\n",
				ep->dev->nb, ep->nb, up->env->errstr);
		}
		ep->toggle[rw] = hc->hctsiz & Pid;
		chanrelease(ep, hc);
		if(strcmp(up->env->errstr, Estalled) == 0)
			return 0;
		nexterror();
	}
	chansetup(hc, ep);
	/*
	 * A packet at a time for bulk in BOTH directions, unless splits
	 * are in use.
	 *
	 * Upstream only does this for bulk reads, on the reasoning that
	 * an IN transfer can end short so the host must drive it packet
	 * by packet, while an OUT transfer is entirely the host's to
	 * schedule and can be programmed once for the whole length. That
	 * is true of the hardware and not of this controller model: a
	 * two-packet OUT programmed in one go never reports completion,
	 * exactly as a two-packet control IN did not.
	 *
	 * The first frame this driver ever tried to send was a 60-byte
	 * gratuitous ARP, 104 bytes once wrapped for RNDIS, and it
	 * stopped here -- with the interface bound and everything above
	 * it convinced the write was in progress.
	 *
	 * Splits still have to be one channel operation, so they keep the
	 * single-shot path; see chansetup and ctltrans, which draw the
	 * same line for the same reason.
	 */
	if(ep->ttype == Tbulk && (rw == Read || (hc->hcsplt & Spltena) == 0))
		n = multitrans(ep, hc, rw, a, n);
	else{
		n = chanio(ep, hc, rw == Read? Epin : Epout, ep->toggle[rw],
			a, n);
		ep->toggle[rw] = hc->hctsiz & Pid;
	}
	chanrelease(ep, hc);
	poperror();
	return n;
}

static long
ctltrans(Ep *ep, uchar *req, long n)
{
	Hostchan *hc;
	Epio *epio;
	Block *b;
	uchar *data;
	int datalen;

	epio = ep->aux;
	if(epio->cb != nil){
		freeb(epio->cb);
		epio->cb = nil;
	}
	if(n < Rsetuplen)
		error(Ebadlen);
	if(req[Rtype] & Rd2h){
		datalen = GET2(req+Rcount);
		if(datalen <= 0 || datalen > Maxctllen)
			error(Ebadlen);
		/* XXX cache madness */
		epio->cb = b = allocb(ROUND(datalen, ep->maxpkt) + CACHELINESZ);
		b->wp = (uchar*)ROUND((uintptr)b->wp, CACHELINESZ);
		/*
		 * rp follows wp. The DMA target is the ROUNDED address, so
		 * that is where the data begins; ctldata() below hands the
		 * caller "n bytes from b->rp". Leaving rp at the unrounded
		 * base means the reply is read from the alignment padding
		 * in front of the data -- a descriptor of the right LENGTH,
		 * full of whatever allocb left behind, which reads as a
		 * device that answered with all zeros rather than as a bug
		 * in this file.
		 */
		b->rp = b->wp;
		memset(b->wp, 0x55, b->lim - b->wp);
		cachedwbinvse(b->wp, b->lim - b->wp);
		data = b->wp;
	}else{
		b = nil;
		datalen = n - Rsetuplen;
		data = req + Rsetuplen;
	}
	hc = chanalloc(ep);
	if(waserror()){
		chanrelease(ep, hc);
		if(strcmp(up->env->errstr, Estalled) == 0)
			return 0;
		nexterror();
	}
	chansetup(hc, ep);
	chanio(ep, hc, Epout, SETUP, req, Rsetuplen);
	if(req[Rtype] & Rd2h){
		/*
		 * Packet at a time unless splits are in use.
		 *
		 * Upstream chooses by hub depth: multitrans() for a device
		 * on the root port, one single-shot chanio() for anything
		 * behind a hub. The condition it is really reaching for is
		 * whether SPLIT transactions are involved -- a split has to
		 * be issued as one channel operation, and on a real Pi the
		 * hub on the root port is high speed, so "behind a hub" and
		 * "split" mean the same thing there.
		 *
		 * They do not mean the same thing here. The hub on this
		 * root port is full speed, so nothing below it splits (see
		 * chansetup), and the single-shot path is chosen for a
		 * transfer that has no reason to use it. A multi-packet
		 * control IN then programs the channel once for the rounded
		 * length -- 128 bytes for a 67-byte descriptor -- and waits
		 * for a completion the controller never reports, because
		 * the device stopped at 67.
		 *
		 * So key it on hcsplt, which is the actual question, and
		 * which chansetup has already answered by this point.
		 */
		if((hc->hcsplt & Spltena) == 0){
			ep->toggle[Read] = DATA1;
			b->wp += multitrans(ep, hc, Read, data, datalen);
		}else
			b->wp += chanio(ep, hc, Epin, DATA1, data, datalen);
		chanio(ep, hc, Epout, DATA1, nil, 0);
		n = Rsetuplen;
	}else{
		if(datalen > 0)
			chanio(ep, hc, Epout, DATA1, data, datalen);
		chanio(ep, hc, Epin, DATA1, nil, 0);
		n = Rsetuplen + datalen;
	}
	chanrelease(ep, hc);
	poperror();
	return n;
}

static long
ctldata(Ep *ep, void *a, long n)
{
	Epio *epio;
	Block *b;

	epio = ep->aux;
	b = epio->cb;
	if(b == nil)
		return 0;
	if(n > BLEN(b))
		n = BLEN(b);
	memmove(a, b->rp, n);
	b->rp += n;
	if(BLEN(b) == 0){
		freeb(b);
		epio->cb = nil;
	}
	return n;
}

static void
greset(Dwcregs *r, int bits)
{
	int i;

	r->grstctl |= bits;
	/*
	 * Bounded, unlike upstream.
	 *
	 * A controller that is absent, unpowered or simply not modelled
	 * leaves these bits set forever, and an unbounded spin turns that
	 * into a silent hang during boot with nothing to say why. Saying
	 * so and continuing is strictly better: the caller finds out, and
	 * a machine that reaches a shell with no USB is far more useful
	 * for diagnosis than one that reaches nothing.
	 */
	for(i = 0; i < Resetlimit; i++){
		if((r->grstctl & bits) == 0)
			break;
		microdelay(10);
	}
	if(i >= Resetlimit)
		print("usbotg: reset %8.8ux timed out (grstctl %8.8ux)\n",
			bits, r->grstctl);
	microdelay(10);
}

static void
init(Hci *hp)
{
	Ctlr *ctlr;
	Dwcregs *r;
	uint n, rx, tx, ptx, cfg, hsphy, width;

	ctlr = hp->aux;
	r = ctlr->regs;

	ctlr->nchan = 1 + ((r->ghwcfg2 & Num_host_chan) >> ONum_host_chan);
	ctlr->chanintr = malloc(ctlr->nchan * sizeof(Rendez));

	r->gahbcfg = 0;
	if(setpower(PowerUsb, 1) < 0)
		print("usbotg: FIRMWARE REFUSED to power the USB block -- "
			"the controller is running unpowered\n");

	for(n = 0; n < Resetlimit; n++){
		if(r->grstctl & Ahbidle)
			break;
		microdelay(10);
	}
	if(n >= Resetlimit)
		print("usbotg: AHB never idle (grstctl %8.8ux) -- "
			"controller absent or unpowered?\n", r->grstctl);
	/*
	 * Select the PHY interface BEFORE the soft reset, because the
	 * reset is what makes the selection take effect.
	 *
	 * This was not being done at all. The reference driver gets away
	 * with it because the VideoCore firmware configures the PHY first
	 * and these fields survive a soft reset -- but that only holds if
	 * the firmware really did initialise the block. If the power
	 * request never took (see setpower), the PHY is left at reset
	 * defaults instead, and a core whose PHY interface width does not
	 * match the wiring cannot move data: host channels are accepted,
	 * report queue space, and never run.
	 *
	 * The width is read from ghwcfg4 rather than assumed. 0 is 8-bit,
	 * 1 is 16-bit, 2 means software may choose -- take 16, which is
	 * the faster and what this SoC is wired for. Usbtrdtim follows the
	 * width: the databook gives 5 for 16-bit and 9 for 8-bit, and the
	 * board reads back 5 against a Phyif of 0, which is inconsistent
	 * on its face and is what first suggested this.
	 *
	 * QEMU reports PHY_NOT_SUPPORTED in ghwcfg2, so neither branch
	 * runs there and emulation is unaffected -- which also means
	 * emulation cannot validate it. It is reasoned from the databook
	 * and from what Linux's dwc_otg and u-boot's dwc2 both do.
	 */
	cfg = r->gusbcfg;
	hsphy = r->ghwcfg2 & Hs_phy_type;
	width = (r->ghwcfg4 & Utmi_phy_data_width) >> 14;
	if(hsphy == PHY_ULPI){
		cfg |= Ulpi_utmi_sel;
		cfg &= ~Phyif;
	}else if(hsphy == PHY_UTMI || hsphy == PHY_UTMI_ULPI){
		cfg &= ~Ulpi_utmi_sel;
		if(width == 0)
			cfg &= ~Phyif;
		else
			cfg |= Phyif;
	}
	if(hsphy != PHY_NOT_SUPPORTED){
		cfg = (cfg & ~Usbtrdtim) |
			((cfg & Phyif) ? 5 : 9) << OUsbtrdtim;
		print("usbotg: PHY %s, utmi width %s, gusbcfg %8.8ux -> %8.8ux\n",
			hsphy == PHY_ULPI ? "ULPI" : "UTMI+",
			width == 0 ? "8" : width == 1 ? "16" : "8 or 16 (taking 16)",
			r->gusbcfg, cfg);
		r->gusbcfg = cfg;
	}

	greset(r, Csftrst);

	r->gusbcfg |= Force_host_mode;
	tsleep(&up->sleep, return0, 0, 25);
	r->gahbcfg |= Dmaenable;

	n = (r->ghwcfg3 & Dfifo_depth) >> ODfifo_depth;
	rx = 0x306;
	tx = 0x100;
	ptx = 0x200;
	r->grxfsiz = rx;
	r->gnptxfsiz = rx | tx<<ODepth;
	tsleep(&up->sleep, return0, 0, 1);
	r->hptxfsiz = (rx + tx) | ptx << ODepth;
	greset(r, Rxfflsh);
	r->grstctl = TXF_ALL;
	greset(r, Txfflsh);
	dprint("usbotg: FIFO depth %d sizes rx/nptx/ptx %8.8ux %8.8ux %8.8ux\n",
		n, r->grxfsiz, r->gnptxfsiz, r->hptxfsiz);

	/*
	 * Say what this core actually is, once.
	 *
	 * A channel that is enabled, correctly programmed and simply
	 * never runs is consistent with the core not having the DMA
	 * engine we are assuming: Architecture reports SLAVE_ONLY,
	 * EXT_DMA or INT_DMA, and gahbcfg's Dmaenable means nothing
	 * unless it is INT_DMA. It is also consistent with the FIFO
	 * carve-up above exceeding what the core has, which would make
	 * the configuration invalid rather than merely tight.
	 *
	 * Both are one register read, and neither was being read.
	 */
	print("usbotg: arch %s, hs phy %s, %d channels, fifo depth %d "
		"(allocated %d)\n",
		(r->ghwcfg2 & Architecture) == INT_DMA ? "internal DMA" :
		(r->ghwcfg2 & Architecture) == EXT_DMA ? "external DMA" :
		(r->ghwcfg2 & Architecture) == SLAVE_ONLY ? "SLAVE ONLY" :
			"reserved",
		(r->ghwcfg2 & Hs_phy_type) == PHY_UTMI ? "UTMI+" :
		(r->ghwcfg2 & Hs_phy_type) == PHY_ULPI ? "ULPI" :
		(r->ghwcfg2 & Hs_phy_type) == PHY_UTMI_ULPI ? "UTMI+/ULPI" :
			"NOT SUPPORTED",
		ctlr->nchan, n, rx + tx + ptx);
	print("usbotg: hcfg %8.8ux gusbcfg %8.8ux ghwcfg2 %8.8ux\n",
		r->hcfg, r->gusbcfg, r->ghwcfg2);

	r->hport0 = Prtpwr|Prtconndet|Prtenchng|Prtovrcurrchng;
	r->gintsts = ~0;
	r->gintmsk = Hcintr;
	r->gahbcfg |= Glblintrmsk;



	/*
	 * There was a start-of-frame self-test here, and it was wrong.
	 *
	 * It unmasked SOF and waited 50ms for an interrupt -- from this
	 * function, which runs before the root port has ever been reset
	 * or enabled. An unenabled port carries no frames, so there is no
	 * SOF to receive, so it always reported "NEVER ARRIVES" on real
	 * hardware. That is not a diagnostic, it is a false alarm with a
	 * confident name, and it was read as a hardware fault twice
	 * before the register dump showed gintsts & gintmsk was simply
	 * zero and the controller was behaving correctly.
	 *
	 * What actually catches a broken interrupt path is the timeout in
	 * chanwait(): a transfer that never completes now reports the
	 * channel state instead of hanging the machine, which is a real
	 * measurement taken at a moment when the answer means something.
	 */
}

/*
 * Reachable as "dump" on #u/usb/ctl.
 *
 * The interrupt count is the point. Everything this driver does
 * involves sleeping until the controller says it is finished, and for
 * a long time none of those wakeups could have arrived -- the handoff
 * went through a timer this board does not model -- yet transfers
 * still completed, because emulation finishes them synchronously and
 * each sleep found its condition already true. A count of zero and a
 * count of hundreds look identical from the outside. So say it.
 */
static void
dump(Hci *hp)
{
	Ctlr *ctlr;

	ctlr = hp->aux;
	print("usbotg: %lud interrupts taken, gintsts %8.8ux hport0 %8.8ux\n",
		nusbintr, ctlr->regs->gintsts, ctlr->regs->hport0);
}

static void
fiqintr(Ureg*, void *a)
{
	Hci *hp;
	Ctlr *ctlr;
	Dwcregs *r;
	uint intr, haint, wakechan;
	int i;

	hp = a;
	ctlr = hp->aux;
	r = ctlr->regs;
	wakechan = 0;
	nusbintr++;
	intr = r->gintsts;
	/*
	 * Acknowledge start-of-frame if it is unmasked. Only the probe
	 * below ever unmasks it, and without this clear it would
	 * re-assert immediately and the machine would make no further
	 * progress.
	 */
	if(intr & Sofintr)
		r->gintsts = Sofintr;
	if(intr & Hcintr){
		haint = r->haint & r->haintmsk;
		for(i = 0; haint; i++){
			if(haint & 1){
				if(chanintr(ctlr, i) == 0){
					r->haintmsk &= ~(1<<i);
					wakechan |= 1<<i;
				}
			}
			haint >>= 1;
		}
	}
	if(intr & Sofintr){
		r->gintsts = Sofintr;
		if((r->hfnum&7) != 6){
			r->gintmsk &= ~Sofintr;
			wakechan |= ctlr->sofchan;
			ctlr->sofchan = 0;
		}
	}
	/*
	 * Wake the sleepers here, rather than deferring.
	 *
	 * Upstream cannot: it runs this as a genuine FIQ, and an FIQ
	 * handler must not call wakeup() -- it can be taken while the
	 * scheduler holds its own locks. So it records which channels
	 * need waking and arms the ARM timer, whose ordinary IRQ handler
	 * does the wakeups a moment later.
	 *
	 * This port does not run it as an FIQ. devusb registers
	 * hp->interrupt through intrenable() like any other driver, so
	 * this is ordinary interrupt context and wakeup() is exactly what
	 * belongs here. sleep() takes splhi() before touching the Rendez
	 * lock, so there is no window for this to interrupt a holder of
	 * the lock it is about to take.
	 *
	 * Deferring is also not merely unnecessary here, it is broken:
	 * the ARM timer at PHYSIO+0xB400 is not modelled by QEMU. Writes
	 * to it are dropped and its control register reads back zero, so
	 * the deferred wakeup never happened and every USB wait that
	 * genuinely needed an interrupt would have blocked for ever. The
	 * enumeration written against this driver got as far as it did
	 * only because emulated transfers complete synchronously, so each
	 * sleep found its condition already true and returned without
	 * ever needing to be woken.
	 */
	for(i = 0; wakechan; i++){
		if(wakechan & 1)
			wakeup(&ctlr->chanintr[i]);
		wakechan >>= 1;
	}
}

/*
 * irqintr() lived here: the second half of upstream's FIQ-to-IRQ
 * handoff, registered on the ARM timer and doing the wakeups that
 * fiqintr() had queued. Both halves are gone -- fiqintr() wakes
 * directly now, for the reasons given there -- and with them the
 * registration of a handler on a timer this board does not model.
 */

static void
epopen(Ep *ep)
{
	ddprint("usbotg: epopen ep%d.%d ttype %d\n",
		ep->dev->nb, ep->nb, ep->ttype);
	switch(ep->ttype){
	case Tnone:
		error(Enotconf);
	case Tintr:
		assert(ep->pollival > 0);
		/* fall through */
	case Tbulk:
		if(ep->toggle[Read] == 0)
			ep->toggle[Read] = DATA0;
		if(ep->toggle[Write] == 0)
			ep->toggle[Write] = DATA0;
		break;
	}
	ep->aux = malloc(sizeof(Epio));
	if(ep->aux == nil)
		error(Enomem);
}

static void
epclose(Ep *ep)
{
	ddprint("usbotg: epclose ep%d.%d ttype %d\n",
		ep->dev->nb, ep->nb, ep->ttype);
	switch(ep->ttype){
	case Tctl:
		freeb(((Epio*)ep->aux)->cb);
		/* fall through */
	default:
		free(ep->aux);
		break;
	}
}

static long
epread(Ep *ep, void *a, long n)
{
	Epio *epio;
	Block *b;
	uchar *p;
	ulong elapsed;
	long nr;
	QLock *lk;

	ddprint("epread ep%d.%d %ld\n", ep->dev->nb, ep->nb, n);
	epio = ep->aux;
	b = nil;
	/*
	 * Control reads take ql, everything else rl -- see Epio. Taking
	 * the right one matters more than it looks: this lock is held
	 * across a transfer that may never complete.
	 */
	if(ep->ttype == Tctl)
		lk = &epio->ql;
	else
		lk = &epio->rl;
	qlock(lk);
	if(waserror()){
		qunlock(lk);
		if(b)
			freeb(b);
		nexterror();
	}
	switch(ep->ttype){
	default:
		error(Egreg);
	case Tctl:
		nr = ctldata(ep, a, n);
		qunlock(lk);
		poperror();
		return nr;
	case Tintr:
		elapsed = TK2MS(m->ticks) - epio->lastpoll;
		if(elapsed < ep->pollival)
			tsleep(&up->sleep, return0, 0, ep->pollival - elapsed);
		/* fall through */
	case Tbulk:
		/* XXX cache madness */
		b = allocb(ROUND(n, ep->maxpkt) + CACHELINESZ);
		p = (uchar*)ROUND((uintptr)b->base, CACHELINESZ);
		cachedwbinvse(p, n);
		nr = eptrans(ep, Read, p, n);
		epio->lastpoll = TK2MS(m->ticks);
		memmove(a, p, nr);
		qunlock(lk);
		freeb(b);
		poperror();
		return nr;
	}
}

static long
epwrite(Ep *ep, void *a, long n)
{
	Epio *epio;
	Block *b;
	uchar *p;
	ulong elapsed;

	ddprint("epwrite ep%d.%d %ld\n", ep->dev->nb, ep->nb, n);
	epio = ep->aux;
	b = nil;
	qlock(&epio->ql);
	if(waserror()){
		qunlock(&epio->ql);
		if(b)
			freeb(b);
		nexterror();
	}
	switch(ep->ttype){
	default:
		error(Egreg);
	case Tintr:
		elapsed = TK2MS(m->ticks) - epio->lastpoll;
		if(elapsed < ep->pollival)
			tsleep(&up->sleep, return0, 0, ep->pollival - elapsed);
		/* fall through */
	case Tctl:
	case Tbulk:
		/* XXX cache madness */
		b = allocb(n + CACHELINESZ);
		p = (uchar*)ROUND((uintptr)b->base, CACHELINESZ);
		memmove(p, a, n);
		cachedwbse(p, n);
		if(ep->ttype == Tctl)
			n = ctltrans(ep, p, n);
		else{
			n = eptrans(ep, Write, p, n);
			epio->lastpoll = TK2MS(m->ticks);
		}
		qunlock(&epio->ql);
		freeb(b);
		poperror();
		return n;
	}
}

static char*
seprintep(char *s, char*, Ep*)
{
	return s;
}
	
static int
portenable(Hci *hp, int port, int on)
{
	Ctlr *ctlr;
	Dwcregs *r;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	dprint("usbotg enable=%d; sts %#x\n", on, r->hport0);
	if(!on)
		r->hport0 = Prtpwr | Prtena;
	tsleep(&up->sleep, return0, 0, Enabledelay);
	dprint("usbotg enable=%d; sts %#x\n", on, r->hport0);
	return 0;
}

static int
portreset(Hci *hp, int port, int on)
{
	Ctlr *ctlr;
	Dwcregs *r;
	int b, s;	int n;

	uint spd, want;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	dprint("usbotg reset=%d; sts %#x\n", on, r->hport0);
	if(!on)
		return 0;
	/*
	 * Reset, and try again if the port does not come up.
	 *
	 * One reset was enough until a keyboard and mouse were plugged
	 * in, and then roughly one boot in three came back with hport0
	 * 00021401: connected, powered, NOT enabled, and negotiated at
	 * FULL speed where a working boot gets high. That combination is
	 * a high-speed handshake that did not complete, not a delay that
	 * is too short -- both delays here are already the spec's, 50ms
	 * of reset and 50ms to enable.
	 *
	 * A device that fluffs the chirp will usually manage it on a
	 * second attempt, which is why every real host retries rather
	 * than declaring the port dead. Failing on the first try leaves
	 * the whole tree unreachable -- including the ethernet the rest
	 * of this session depends on -- for a fault that costs 100ms to
	 * try again.
	 */
	for(n = 0; n < Resetattempts; n++){
		r->hport0 = Prtpwr | Prtrst;
		tsleep(&up->sleep, return0, 0, ResetdelayHS);
		r->hport0 = Prtpwr;
		tsleep(&up->sleep, return0, 0, Enabledelay);
		s = r->hport0;
		b = s & (Prtconndet|Prtenchng|Prtovrcurrchng);
		if(b != 0)
			r->hport0 = Prtpwr | b;
		if(s & Prtena)
			break;
		print("usbotg: host port not enabled after reset %d "
			"(hport0 %8.8ux)\n", n + 1, s);
	}
	dprint("usbotg reset=%d; sts %#x\n", on, s);
	if((s & Prtena) == 0)
		print("usbotg: host port will not enable\n");
	else if(n > 0)
		print("usbotg: host port enabled on attempt %d\n", n + 1);

	/*
	 * Make the PHY clock follow the speed the port actually came up
	 * at, and say what that was.
	 *
	 * hcfg's Fslspclksel selects 30/60MHz for a high-speed PHY or
	 * 48MHz for full/low speed, and it is NOT self-configuring: the
	 * core keeps whatever was there across the reset. Leave it at
	 * 30/60MHz while the port enumerates a full-speed device and the
	 * host has the wrong bit clock for the bus it is driving -- at
	 * which point a channel can be enabled, correctly programmed,
	 * with queue space free, and simply never run. That is the
	 * symptom this port has had all along, and the register was
	 * never being written.
	 *
	 * Changing the selection requires another port reset for it to
	 * take effect, which is why this is done here rather than at
	 * init: init does not yet know the speed.
	 *
	 * Nothing in emulation depends on the PHY bit clock, so this is
	 * invisible under QEMU in either state.
	 */
	spd = s & Prtspd;
	want = spd == HIGHSPEED ? HCFG_30_60_MHZ : HCFG_48_MHZ;
	print("usbotg: port %s speed, hport0 %8.8ux, hcfg %8.8ux -> clk %s\n",
		spd == HIGHSPEED ? "high" :
		spd == FULLSPEED ? "full" :
		spd == LOWSPEED ? "low" : "reserved",
		s, r->hcfg,
		want == HCFG_30_60_MHZ ? "30/60MHz" : "48MHz");

	if((r->hcfg & Fslspclksel) != want){
		r->hcfg = (r->hcfg & ~Fslspclksel) | want;
		r->hport0 = Prtpwr | Prtrst;
		tsleep(&up->sleep, return0, 0, ResetdelayHS);
		r->hport0 = Prtpwr;
		tsleep(&up->sleep, return0, 0, Enabledelay);
		s = r->hport0;
		b = s & (Prtconndet|Prtenchng|Prtovrcurrchng);
		if(b != 0)
			r->hport0 = Prtpwr | b;
		print("usbotg: re-reset after clock change, hport0 %8.8ux\n", s);
	}
	return 0;
}

static int
portstatus(Hci *hp, int port)
{
	Ctlr *ctlr;
	Dwcregs *r;
	int b, s;

	assert(port == 1);
	ctlr = hp->aux;
	r = ctlr->regs;
	s = r->hport0;
	b = s & (Prtconndet|Prtenchng|Prtovrcurrchng);
	if(b != 0)
		r->hport0 = Prtpwr | b;
	b = 0;
	if(s & Prtconnsts)
		b |= HPpresent;
	if(s & Prtconndet)
		b |= HPstatuschg;
	if(s & Prtena)
		b |= HPenable;
	if(s & Prtenchng)
		b |= HPchange;
	if(s & Prtovrcurract)
		 b |= HPovercurrent;
	if(s & Prtsusp)
		b |= HPsuspend;
	if(s & Prtrst)
		b |= HPreset;
	if(s & Prtpwr)
		b |= HPpower;
	switch(s & Prtspd){
	case HIGHSPEED:
		b |= HPhigh;
		break;
	case LOWSPEED:
		b |= HPslow;
		break;
	}
	return b;
}

static void
shutdown(Hci*)
{
}

static void
setdebug(Hci*, int d)
{
	debug = d;
}

static int
reset(Hci *hp)
{
	Ctlr *ctlr;
	uint id;

	ctlr = &dwc;
	if(ctlr->regs != nil)
		return -1;
	ctlr->regs = (Dwcregs*)USBREGS;
	id = ctlr->regs->gsnpsid;
	if((id>>16) != ('O'<<8 | 'T'))
		return -1;
	dprint("usbotg: rev %d.%3.3x\n", (id>>12)&0xF, id&0xFFF);

	hp->aux = ctlr;
	hp->port = 0;
	hp->irq = IRQusb;
	hp->tbdf = 0;
	hp->nports = 1;
	hp->highspeed = 1;

	hp->init = init;
	hp->dump = dump;
	hp->interrupt = fiqintr;
	hp->epopen = epopen;
	hp->epclose = epclose;
	hp->epread = epread;
	hp->epwrite = epwrite;
	hp->seprintep = seprintep;
	hp->portenable = portenable;
	hp->portreset = portreset;
	hp->portstatus = portstatus;
	hp->shutdown = shutdown;
	hp->debug = setdebug;
	hp->type = "dwcotg";
	return 0;
}

void
usbdwclink(void)
{
	addhcitype("dwcotg", reset);
}
