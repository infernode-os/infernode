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
 * The PHY is found and driven over the GEM's MDIO (Clause 22, the MAN
 * register): the first address that answers with an ID, told to
 * autonegotiate. Its link is polled once a second from the kproc, and
 * when it comes up, NCFGR's speed and duplex are set from what was
 * negotiated and the interface's link and mbps follow. QEMU's GEM has
 * a PHY model (an 88E1111 that is always up at gigabit), which is what
 * this is tested against; a GEM with no PHY answering keeps gigabit full
 * duplex and a link that is always up, as before.
 *
 * On the board the GEM reaches its PHY through the MSS's SGMII block,
 * which the HSS configures and which NCFGR's PCS-select and SGMII-mode
 * bits choose: those two are kept as the firmware left them.
 *
 * Not done: cache coherence of the MAC's DMA, which on a PolarFire
 * depends on which DDR window the buffers are addressed through, and
 * needs the board to answer.
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
	Man		= 0x034,	/* PHY maintenance (MDIO) */
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
	Pcssel		= 1<<11,	/* the PCS, for SGMII: the firmware's choice */
	Sgmiien		= 1<<27,
	Rfcs		= 1<<17,	/* strip the FCS */
	Mdcdiv		= 5<<18,	/* MDC: pclk/96 */
	Dbwshift	= 21,		/* AMBA data bus width: 0 32-bit, 1 64, 2 128 */

	/* Nsr */
	Mdioidle	= 1<<2,

	/* Man: a Clause 22 frame */
	Mansof		= 1<<30,
	Manwrite	= 1<<28,
	Manread		= 2<<28,
	Manphyshift	= 23,
	Manregshift	= 18,
	Mancode		= 2<<16,

	/* Clause 22 registers */
	Bmcr		= 0,
		Bmcranen	= 1<<12,
		Bmcranrestart	= 1<<9,
	Bmsr		= 1,
		Bmsrlink	= 1<<2,
		Bmsrancomp	= 1<<5,
	Phyid1		= 2,
	Phyid2		= 3,
	Anar		= 4,
	Anlpar		= 5,
		An100fd		= 1<<8,
		An100hd		= 1<<7,
		An10fd		= 1<<6,
	Gbcr		= 9,
		Gbcr1000fd	= 1<<9,
	Gbsr		= 10,
		Gbsr1000fd	= 1<<11,

	Nophy		= -1,

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

	int	phy;		/* its MDIO address, or Nophy */
	u32int	phyid;
	u32int	ncfgr;		/* NCFGR less speed and duplex */

	ulong	nintr, nrx, ntx, nrxdrop, ntxfull, nbna, novr;
};

static Ctlr ctlr;

#define	R(c, r)	(*(volatile u32int*)((c)->regs + (r)))

/*
 * One Clause 22 transaction. Only the kproc and gemattach (before the
 * kproc is started) use the MDIO, so nothing else can be mid-frame.
 */
static int
mdiowait(Ctlr *c)
{
	int i;

	for(i = 0; i < 1000; i++){
		if(R(c, Nsr) & Mdioidle)
			return 0;
		microdelay(10);
	}
	return -1;
}

static int
mdioread(Ctlr *c, int phy, int reg)
{
	if(mdiowait(c) < 0)
		return -1;
	R(c, Man) = Mansof | Manread | phy<<Manphyshift | reg<<Manregshift | Mancode;
	if(mdiowait(c) < 0)
		return -1;
	return R(c, Man) & 0xFFFF;
}

static void
mdiowrite(Ctlr *c, int phy, int reg, int v)
{
	if(mdiowait(c) < 0)
		return;
	R(c, Man) = Mansof | Manwrite | phy<<Manphyshift | reg<<Manregshift | Mancode | (v & 0xFFFF);
	mdiowait(c);
}

/* the first address that answers with an ID, told to autonegotiate */
static void
phyprobe(Ctlr *c)
{
	int a, id1, id2, bmcr;

	c->phy = Nophy;
	for(a = 0; a < 32; a++){
		id1 = mdioread(c, a, Phyid1);
		id2 = mdioread(c, a, Phyid2);
		if(id1 < 0 || id2 < 0)
			return;		/* the MDIO itself is not answering */
		if((id1 == 0 && id2 == 0) || (id1 == 0xFFFF && id2 == 0xFFFF))
			continue;
		c->phy = a;
		c->phyid = id1<<16 | id2;
		break;
	}
	if(c->phy == Nophy){
		print("gem: no PHY answers on the MDIO; assuming gigabit full duplex\n");
		return;
	}
	bmcr = mdioread(c, c->phy, Bmcr);
	if(bmcr >= 0)
		mdiowrite(c, c->phy, Bmcr, bmcr | Bmcranen | Bmcranrestart);
	print("gem: PHY %#.8ux at MDIO address %d; autonegotiating\n", c->phyid, c->phy);
}

/*
 * Once a second from the kproc: has the link changed? If it has come
 * up, set the MAC to what was negotiated.
 */
static void
phypoll(Ctlr *c)
{
	Ether *e;
	int bmsr, lpa, adv, gbcr, gbsr, mbps, fd, linkup;
	u32int speed;

	if(c->phy == Nophy)
		return;
	e = c->edev;
	/* the link bit latches low: the second read is now */
	mdioread(c, c->phy, Bmsr);
	bmsr = mdioread(c, c->phy, Bmsr);
	if(bmsr < 0)
		return;
	linkup = (bmsr & Bmsrlink) && (bmsr & Bmsrancomp);
	if(linkup == e->nif.link)
		return;
	if(!linkup){
		e->nif.link = 0;
		print("gem: link down\n");
		return;
	}

	gbcr = mdioread(c, c->phy, Gbcr);
	gbsr = mdioread(c, c->phy, Gbsr);
	adv = mdioread(c, c->phy, Anar);
	lpa = mdioread(c, c->phy, Anlpar);
	if(gbcr >= 0 && gbsr >= 0 && (gbcr & Gbcr1000fd) && (gbsr & Gbsr1000fd)){
		mbps = 1000;
		fd = 1;
	}else if(adv >= 0 && lpa >= 0){
		lpa &= adv;
		if(lpa & (An100fd|An100hd)){
			mbps = 100;
			fd = (lpa & An100fd) != 0;
		}else{
			mbps = 10;
			fd = (lpa & An10fd) != 0;
		}
	}else
		return;

	speed = mbps == 1000 ? Gbe : mbps == 100 ? Spd100 : 0;
	R(c, Ncfgr) = c->ncfgr | speed | (fd ? Fd : 0);
	e->nif.mbps = mbps;
	e->nif.link = 1;
	print("gem: link up, %d Mbps %s duplex\n", mbps, fd ? "full" : "half");
}

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
		/* a second at most, so the PHY is looked at */
		tsleep(&c->r, gemwork, c, 1000);
		c->work = 0;
		phypoll(c);

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
	c->ncfgr = (R(c, Ncfgr) & (Pcssel|Sgmiien)) | Rfcs | Mdcdiv | (i << Dbwshift);
	R(c, Ncfgr) = c->ncfgr | Gbe | Fd;
	R(c, Sa1b) = e->ea[0] | e->ea[1]<<8 | e->ea[2]<<16 | (u32int)e->ea[3]<<24;
	R(c, Sa1t) = e->ea[4] | e->ea[5]<<8;

	c->rxhead = c->txhead = c->txtail = 0;
	R(c, Ncr) = Mpe;
	phyprobe(c);
	/* with a PHY, the link is down until it says otherwise */
	if(c->phy != Nophy)
		e->nif.link = 0;
	phypoll(c);

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
		"gem at %#p irq %d phy %d id %#.8ux\n"
		"intrs %lud rx %lud tx %lud rxdrop %lud txfull %lud bna %lud ovr %lud\n"
		"ncr %#ux ncfgr %#ux nsr %#ux dmacfg %#ux tsr %#ux rsr %#ux imr %#ux\n",
		(void*)c->regs, c->irq, c->phy, c->phyid,
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
	c->phy = Nophy;

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
