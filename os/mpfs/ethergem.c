/*
 * The PolarFire SoC's Ethernet: a Cadence GEM, as a kernel link driver
 * (#l/ether0) in the shape of ../virtio/ethervirtio.c.
 *
 * The GEM moves frames through two rings of descriptors in memory, two
 * words each: a buffer address whose bit 0 is ownership (receive: 1
 * means the GEM has filled it and software owns it) and a status word
 * (transmit: bit 31 the same ownership, set by the GEM when the frame
 * has gone). DDR is below 4GB, so the 32-bit descriptor format serves,
 * and the rings and buffers are fixed: a received frame is copied into
 * a Block and its buffer handed straight back, a frame to send is
 * copied into a transmit buffer. Copying 1500 bytes is nothing beside
 * the rest of the path, and fixed buffers make the rings trivially
 * correct.
 *
 * Receive and transmit completion interrupt; the interrupt only wakes
 * a kproc, and the frames are handled there, in process context, where
 * etheriqb may allocate.
 *
 * Under QEMU (hw/net/cadence_gem.c) that is all there is. On the board
 * two things are not done here yet and matter: the PHY (MDIO: its link
 * speed decides NCFGR's speed bits, which are set for gigabit full
 * duplex and left there), and cache coherence of the MAC's DMA, which
 * on a PolarFire depends on which DDR window the buffers are addressed
 * through. Both need the board to answer.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"
#include "board.h"

enum
{
	Ncr		= 0x000,	/* network control */
	Ncfgr		= 0x004,	/* network configuration */
	Nsr		= 0x008,
	Dmacfg		= 0x010,
	Tsr		= 0x014,	/* transmit status */
	Rbqp		= 0x018,	/* receive queue base */
	Tbqp		= 0x01C,	/* transmit queue base */
	Rsr		= 0x020,	/* receive status */
	Isr		= 0x024,	/* interrupt status: clear on read */
	Ier		= 0x028,
	Idr		= 0x02C,
	Imr		= 0x030,
	Sa1b		= 0x088,	/* specific address 1, bottom 32 bits */
	Sa1t		= 0x08C,	/* and top 16 */
	Dcfg1		= 0x280,	/* design configuration: the AMBA data bus width */
	Dcfg6		= 0x294,	/* design configuration: which priority queues exist */
	Tbqp1		= 0x440,	/* priority queue n's transmit base: Tbqp1 + 4(n-1) */
	Rbqp1		= 0x480,

	/* Ncr */
	Re		= 1<<2,
	Te		= 1<<3,
	Mpe		= 1<<4,
	Clrstat		= 1<<5,
	Tstart		= 1<<9,

	/* Ncfgr */
	Spd100		= 1<<0,
	Fd		= 1<<1,
	Gbe		= 1<<10,
	Rfcs		= 1<<17,	/* strip the FCS */
	Mdcdiv		= 5<<18,	/* MDC: pclk/96 */
	Dbwshift	= 21,		/* AMBA data bus width: 0 32-bit, 1 64, 2 128 */

	/* Tsr, Rsr */
	Txcomp		= 1<<5,
	Rxrec		= 1<<1,
	Rxbna		= 1<<0,
	Rxovr		= 1<<2,

	/* interrupts */
	Irxcomp		= 1<<1,
	Irxubr		= 1<<2,
	Itxcomp		= 1<<7,
	Irxovr		= 1<<10,
	Ihresp		= 1<<11,

	/* receive descriptor */
	Rxused		= 1<<0,		/* word 0: software owns it */
	Rxwrap		= 1<<1,
	Rxlenmask	= 0x1FFF,	/* word 1 */

	/* transmit descriptor, word 1 */
	Txlast		= 1<<15,
	Txwrap		= 1<<30,
	Txused		= 1<<31,

	Nrx		= 64,
	Ntx		= 64,
	Bufsize		= 1536,		/* a multiple of 64: Dmacfg's unit */
	Framemax	= 1514,
};

typedef struct Desc Desc;
struct Desc
{
	u32int	addr;
	u32int	ctl;
};

typedef struct Ctlr Ctlr;
struct Ctlr
{
	uintptr	regs;
	int	irq;
	Ether	*edev;
	int	started;

	Desc	*rx;
	Desc	*tx;
	uchar	*rxbuf;
	uchar	*txbuf;
	Desc	*dummy;		/* what an unused priority queue is pointed at */
	int	rxhead;		/* next receive descriptor to look at */
	int	txhead;		/* next transmit descriptor to fill */
	int	txtail;		/* oldest not yet seen sent */

	QLock	tlock;
	Rendez	r;
	int	work;

	ulong	nintr, nrx, ntx, nrxdrop, ntxfull, nbna, novr;
};

static Ctlr ctlr;

#define	R(c, r)	(*(volatile u32int*)((c)->regs + (r)))

static void
geminterrupt(Ureg*, void *a)
{
	Ctlr *c;
	u32int isr;

	c = a;
	isr = R(c, Isr);
	if(isr == 0)
		return;
	c->nintr++;
	if(isr & Irxubr)
		c->nbna++;
	if(isr & Irxovr)
		c->novr++;
	c->work = 1;
	wakeup(&c->r);
}

static int
gemwork(void *a)
{
	return ((Ctlr*)a)->work;
}

static void
txreap(Ctlr *c)
{
	while(c->txtail != c->txhead && (c->tx[c->txtail].ctl & Txused)){
		c->txtail = (c->txtail + 1) % Ntx;
		c->ntx++;
	}
	R(c, Tsr) = Txcomp;
}

static void
gemtransmit(Ether *e)
{
	Ctlr *c;
	Block *b;
	Desc *d;
	int n, next, sent;

	c = e->ctlr;
	if(c == nil || !c->started)
		return;
	sent = 0;
	qlock(&c->tlock);
	txreap(c);
	for(;;){
		next = (c->txhead + 1) % Ntx;
		if(next == c->txtail){
			if(qlen(e->oq) > 0)
				c->ntxfull++;
			break;
		}
		if((b = qget(e->oq)) == nil)
			break;
		n = BLEN(b);
		if(n > Framemax){
			freeb(b);
			e->nif.oerrs++;
			continue;
		}
		d = &c->tx[c->txhead];
		memmove(c->txbuf + c->txhead*Bufsize, b->rp, n);
		freeb(b);
		coherence();
		d->ctl = (n & 0x3FFF) | Txlast | (c->txhead == Ntx-1 ? Txwrap : 0);
		c->txhead = next;
		e->nif.outpackets++;
		sent = 1;
	}
	qunlock(&c->tlock);
	if(sent){
		coherence();
		R(c, Ncr) |= Tstart;
	}
}

static void
gemproc(void *a)
{
	Ctlr *c;
	Ether *e;
	Desc *d;
	Block *b;
	int n;

	c = a;
	e = c->edev;
	for(;;){
		sleep(&c->r, gemwork, c);
		c->work = 0;

		for(;;){
			d = &c->rx[c->rxhead];
			if((d->addr & Rxused) == 0)
				break;
			coherence();
			n = d->ctl & Rxlenmask;
			if(n <= 0 || n > Framemax || (b = allocb(n)) == nil)
				c->nrxdrop++;
			else{
				memmove(b->wp, c->rxbuf + c->rxhead*Bufsize, n);
				b->wp += n;
				c->nrx++;
				etheriqb(e, b);
			}
			d->ctl = 0;
			coherence();
			d->addr &= ~Rxused;	/* the GEM's again */
			c->rxhead = (c->rxhead + 1) % Nrx;
		}
		R(c, Rsr) = Rxrec | Rxbna | Rxovr;

		gemtransmit(e);
	}
}

static void
gemattach(Ether *e)
{
	Ctlr *c;
	int i;
	u32int dcfg6;

	c = e->ctlr;
	qlock(&c->tlock);
	if(c->started){
		qunlock(&c->tlock);
		return;
	}

	for(i = 0; i < Nrx; i++){
		c->rx[i].addr = (u32int)PADDR(c->rxbuf + i*Bufsize) | (i == Nrx-1 ? Rxwrap : 0);
		c->rx[i].ctl = 0;
	}
	for(i = 0; i < Ntx; i++){
		c->tx[i].addr = (u32int)PADDR(c->txbuf + i*Bufsize);
		c->tx[i].ctl = Txused | (i == Ntx-1 ? Txwrap : 0);
	}
	c->dummy->addr = Rxused | Rxwrap;
	c->dummy->ctl = Txused | Txwrap;
	coherence();

	R(c, Ncr) = 0;
	R(c, Ncr) = Clrstat;
	R(c, Tsr) = ~0;
	R(c, Rsr) = ~0;
	R(c, Idr) = ~0;
	(void)R(c, Isr);

	R(c, Rbqp) = (u32int)PADDR(c->rx);
	R(c, Tbqp) = (u32int)PADDR(c->tx);
	/* the priority queues this GEM has and nobody uses: parked on a used descriptor */
	dcfg6 = R(c, Dcfg6);
	for(i = 1; i < 16; i++)
		if(dcfg6 & (1<<i)){
			R(c, Tbqp1 + 4*(i-1)) = (u32int)PADDR(c->dummy);
			R(c, Rbqp1 + 4*(i-1)) = (u32int)PADDR(c->dummy);
		}

	R(c, Dmacfg) = ((Bufsize/64) << 16) | (3<<8) | (1<<10) | 0x10;	/* rx buffer size, full packet memories, burst 16 */
	/* the bus width the GEM was built with (DCFG1 27:25: 1, 2, 4 for 32, 64, 128) */
	i = (R(c, Dcfg1) >> 25) & 7;
	i = i >= 4 ? 2 : i >= 2 ? 1 : 0;
	R(c, Ncfgr) = Spd100 | Fd | Gbe | Rfcs | Mdcdiv | (i << Dbwshift);
	R(c, Sa1b) = e->ea[0] | e->ea[1]<<8 | e->ea[2]<<16 | (u32int)e->ea[3]<<24;
	R(c, Sa1t) = e->ea[4] | e->ea[5]<<8;

	c->rxhead = c->txhead = c->txtail = 0;
	intrenable(c->irq, geminterrupt, c, 0, "gem");
	R(c, Ier) = Irxcomp | Irxubr | Itxcomp | Irxovr | Ihresp;
	R(c, Ncr) = Re | Te | Mpe;
	c->started = 1;
	qunlock(&c->tlock);
	kproc("gem", gemproc, c, 0);
}

static long
gemifstat(Ether *e, void *a, long n, ulong off)
{
	Ctlr *c;
	char *p;

	c = e->ctlr;
	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	snprint(p, READSTR,
		"gem at %#p irq %d\n"
		"intrs %lud rx %lud tx %lud rxdrop %lud txfull %lud bna %lud ovr %lud\n"
		"ncr %#ux ncfgr %#ux nsr %#ux dmacfg %#ux tsr %#ux rsr %#ux imr %#ux\n",
		(void*)c->regs, c->irq,
		c->nintr, c->nrx, c->ntx, c->nrxdrop, c->ntxfull, c->nbna, c->novr,
		R(c, Ncr), R(c, Ncfgr), R(c, Nsr), R(c, Dmacfg), R(c, Tsr), R(c, Rsr), R(c, Imr));
	n = readstr(off, a, n, p);
	free(p);
	return n;
}

void
ethergemlink(void)
{
	Ctlr *c;
	Ether *e;
	u32int lo, hi;

	c = &ctlr;
	c->regs = GEM0REGS;
	c->irq = IRQgem0;

	e = etherinstance(0);
	if(e == nil)
		return;

	c->rx = xspanalloc(Nrx*sizeof(Desc), 64, 0);
	c->tx = xspanalloc(Ntx*sizeof(Desc), 64, 0);
	c->dummy = xspanalloc(sizeof(Desc), 64, 0);
	c->rxbuf = xspanalloc(Nrx*Bufsize, 64, 0);
	c->txbuf = xspanalloc(Ntx*Bufsize, 64, 0);
	if(c->rx == nil || c->tx == nil || c->dummy == nil || c->rxbuf == nil || c->txbuf == nil){
		print("gem: no memory for the rings\n");
		return;
	}

	/*
	 * The address: whatever the firmware (or QEMU, from -nic) left in
	 * specific-address register 1, or a locally administered one if
	 * nothing did.
	 */
	lo = R(c, Sa1b);
	hi = R(c, Sa1t) & 0xFFFF;
	if(lo == 0 && hi == 0){
		lo = 0x0012A502;	/* 02:a5:12:00:.. locally administered */
		hi = 0x0001;
	}
	e->ea[0] = lo;
	e->ea[1] = lo >> 8;
	e->ea[2] = lo >> 16;
	e->ea[3] = lo >> 24;
	e->ea[4] = hi;
	e->ea[5] = hi >> 8;
	memmove(e->nif.addr, e->ea, Eaddrlen);
	e->nif.alen = Eaddrlen;
	memset(e->nif.bcast, 0xFF, Eaddrlen);
	e->nif.mbps = 1000;
	e->nif.link = 1;

	c->edev = e;
	e->ctlr = c;
	e->attach = gemattach;
	e->transmit = gemtransmit;
	e->ifstat = gemifstat;

	print("ether: gem0 %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux is #l (ether0)\n",
		e->ea[0], e->ea[1], e->ea[2], e->ea[3], e->ea[4], e->ea[5]);
}
