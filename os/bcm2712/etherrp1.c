/*
 * The gigabit port: a Cadence GEM in RP1, with a BCM54213 PHY.
 *
 * From Linux's macb driver and Circle's port of it (lib/macb.cpp), to
 * ../port/etherif.h's shape. Rings and transmit buffers are in 2MB of
 * Normal non-cacheable memory; a frame is copied in and out, and receive
 * buffers are cached, because reading non-cacheable memory is what
 * limited it.
 *
 * With the firmware's bridge setup, which this kernel keeps, RP1 reaches
 * memory at the physical address itself: PCIe 0 is RAM 0 (RC_BAR2). Not
 * Linux's 0x10_0000_0000, which is Linux's own programming of the bridge
 * and took frames nowhere here. RP1's own registers are at PCIe
 * 0x80000000, so a buffer must be below that: Dmalimit.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"
#include "board.h"

#define GEM(o)		(ctlr->r[(o)/4])
#define RP1REG(o)	(*(volatile u32int*)(uintptr)(RP1REGS + (o)))

enum
{
	Ncr		= 0x000,
		Rxen	= 1<<2,
		Txen	= 1<<3,
		Mpe	= 1<<4,
		Clrstat	= 1<<5,
		Tstart	= 1<<9,
		Thalt	= 1<<10,
	Ncfgr		= 0x004,
		Spd100	= 1<<0,
		Fd	= 1<<1,
		Caf	= 1<<4,
		Mti	= 1<<6,
		Gbe	= 1<<10,
		Drfcs	= 1<<17,
		Mdcshift= 18,
		Mdcdiv96= 5,		/* RP1's 200MHz: Linux's table */
		Dbwshift= 21,
	Nsr		= 0x008,
		Mdidle	= 1<<2,
	Usrio		= 0x00C,
		Rgmii	= 1<<0,
	Dmacfg		= 0x010,
		Addr64	= 1<<30,
		Txpbms	= 1<<10,
		Rxbms	= 3<<8,
		Rxbsshift= 16,
	Tsr		= 0x014,
		Tgo	= 1<<3,
	Rbqp		= 0x018,
	Tbqp		= 0x01C,
	Isr		= 0x024,
		Irxcomp	= 1<<1,
		Itxcomp	= 1<<7,
	Ier		= 0x028,
	Idr		= 0x02C,
	Intmod		= 0x05C,	/* in 800ns: 40us on the receive side */
	Man		= 0x034,
	Hrb		= 0x080,
	Hrt		= 0x084,
	Sa1b		= 0x088,
	Sa1t		= 0x08C,
	Mid		= 0x0FC,
	Dcfg1		= 0x280,
	Dcfg6		= 0x294,
	Tbqpq		= 0x440,	/* the other queues' bases, by queue */
	Rbqpq		= 0x480,
	Tbqph		= 0x4C8,
	Rbqph		= 0x4D4,

	Rxused		= 1<<0,		/* in addr */
	Rxwrap		= 1<<1,
	Rxsof		= 1<<14,	/* in ctrl */
	Rxeof		= 1<<15,
	Rxlen		= 0xFFF,
	Txlast		= 1<<15,
	Txwrap		= 1<<30,
	Txused		= 1<<31,

	Bsz		= 2048,
	Nrx		= 1024,
	Ntx		= 64,
	Dmasize		= 2*1024*1024,
	Dmalimit	= 0x80000000,

	Bmcr		= 0,
	Bmsr		= 1,
		Linkup	= 1<<2,
		Andone	= 1<<5,
	Anar		= 4,
	Anlpar		= 5,
	Gtcr		= 9,
	Gtsr		= 10,
};

typedef struct Desc Desc;
struct Desc
{
	u32int	addr;
	u32int	ctrl;
	u32int	addrh;
	u32int	unused;
};

typedef struct Ctlr Ctlr;
struct Ctlr
{
	volatile u32int	*r;
	QLock	alock;
	int	attached;
	int	phy;

	volatile Desc	*rx;
	volatile Desc	*tx;
	volatile Desc	*dummy;
	uchar	*rbuf;
	uchar	*tbuf;
	int	rxtail;
	int	txhead;
	int	txdone;

	Rendez	rr;
	Rendez	tr;
	Rendez	lr;
	ulong	nintr;
	ulong	nrx;
	ulong	nrxbad;
	ulong	ntx;
	ulong	nmdiotimeout;
};

static int
mdioidle(Ctlr *ctlr)
{
	int i;

	for(i = 0; i < 100000; i++){
		if(GEM(Nsr) & Mdidle)
			return 0;
		microdelay(1);
	}
	ctlr->nmdiotimeout++;
	return -1;
}

static int
mdior(Ctlr *ctlr, int reg)
{
	int v;

	GEM(Man) = 1<<30 | 2<<28 | ctlr->phy<<23 | reg<<18 | 2<<16;
	if(mdioidle(ctlr) < 0)
		return -1;
	v = GEM(Man) & 0xFFFF;
	return v;
}

static void
mdiow(Ctlr *ctlr, int reg, int v)
{
	GEM(Man) = 1<<30 | 1<<28 | ctlr->phy<<23 | reg<<18 | 2<<16 | v;
	mdioidle(ctlr);
}

static void
setaddr(volatile Desc *d, uintptr pa, u32int flags)
{
	d->addrh = 0;
	coherence();
	d->addr = (u32int)pa | flags;
}

static int
rxready(void *arg)
{
	Ctlr *ctlr;

	ctlr = arg;
	return (ctlr->rx[ctlr->rxtail].addr & Rxused) != 0;
}

static int
txready(void *arg)
{
	return (((volatile Desc*)arg)->ctrl & Txused) != 0;
}

static void
interrupt(Ureg*, void *arg)
{
	Ctlr *ctlr;
	u32int s;

	ctlr = ((Ether*)arg)->ctlr;
	s = GEM(Isr);
	GEM(Isr) = s;
	ctlr->nintr++;
	if(s & Irxcomp)
		wakeup(&ctlr->rr);
	if(s & Itxcomp)
		wakeup(&ctlr->tr);
}

static void
recvproc(void *arg)
{
	Ether *edev;
	Ctlr *ctlr;
	volatile Desc *d;
	Block *b;
	u32int ctl, addr;
	int len;

	edev = arg;
	ctlr = edev->ctlr;
	while(waserror())
		;
	for(;;){
		d = &ctlr->rx[ctlr->rxtail];
		coherence();
		addr = d->addr;
		if((addr & Rxused) == 0){
			tsleep(&ctlr->rr, rxready, ctlr, 100);
			continue;
		}
		ctl = d->ctrl;
		len = ctl & Rxlen;
		if((ctl & (Rxsof|Rxeof)) != (Rxsof|Rxeof) || len == 0 || len > Bsz)
			ctlr->nrxbad++;
		else if((b = allocb(len)) == nil)
			ctlr->nrxbad++;
		else{
			/* cached, and never written from this side: only stale lines to drop */
			cachedwbinvse(ctlr->rbuf + ctlr->rxtail*Bsz, len);
			memmove(b->wp, ctlr->rbuf + ctlr->rxtail*Bsz, len);
			b->wp += len;
			ctlr->nrx++;
			edev->nif.inpackets++;
			etheriqb(edev, b);
		}
		d->ctrl = 0;
		coherence();
		d->addr = addr & ~Rxused;
		coherence();
		ctlr->rxtail = (ctlr->rxtail + 1) % Nrx;
	}
}

static void
sendproc(void *arg)
{
	Ether *edev;
	Ctlr *ctlr;
	volatile Desc *d;
	Block *b;
	u32int ctl;
	int n;

	edev = arg;
	ctlr = edev->ctlr;
	while(waserror())
		;
	for(;;){
		if((b = qbread(edev->oq, 100000)) == nil)
			continue;
		n = BLEN(b);
		if(n <= 0 || n > Bsz){
			freeb(b);
			continue;
		}
		d = &ctlr->tx[ctlr->txhead];
		while((d->ctrl & Txused) == 0){		/* the ring is full */
			coherence();
			tsleep(&ctlr->tr, txready, (void*)d, 100);
		}
		memmove(ctlr->tbuf + ctlr->txhead*Bsz, b->rp, n);
		freeb(b);
		ctl = n | Txlast;
		if(ctlr->txhead == Ntx-1)
			ctl |= Txwrap;
		coherence();
		d->ctrl = ctl;		/* clears Txused: it is the MAC's */
		coherence();
		GEM(Ncr) |= Tstart;
		ctlr->txhead = (ctlr->txhead + 1) % Ntx;
		ctlr->ntx++;
		edev->nif.outpackets++;
	}
}

static void
transmit(Ether*)
{
	/* sendproc sleeps on oq */
}

static void
linkset(Ether *edev)
{
	Ctlr *ctlr;
	u32int cfg;
	int g, lp, mbps, fd;

	ctlr = edev->ctlr;
	cfg = GEM(Ncfgr) & ~(Spd100|Fd|Gbe);
	g = mdior(ctlr, Gtsr);		/* what the partner offers, in 1000BASE-T */
	if(g > 0)
		g &= mdior(ctlr, Gtcr)<<2;	/* and we */
	if(g > 0 && (g & (3<<10)) != 0){
		mbps = 1000;
		fd = (g & (1<<11)) != 0;
		cfg |= Gbe;
	}else{
		lp = mdior(ctlr, Anlpar) & mdior(ctlr, Anar);
		if(lp & (3<<7)){
			mbps = 100;
			fd = (lp & (1<<8)) != 0;
			cfg |= Spd100;
		}else{
			mbps = 10;
			fd = (lp & (1<<6)) != 0;
		}
	}
	if(fd)
		cfg |= Fd;
	GEM(Ncfgr) = cfg;		/* the block divides its tx clock itself: it is left alone */
	edev->nif.mbps = mbps;
	print("#l%d: rp1: link up, %d Mbit/s, %s duplex\n", edev->ctlrno, mbps, fd ? "full" : "half");
}

static void
linkproc(void *arg)
{
	Ether *edev;
	Ctlr *ctlr;
	int s, link;

	edev = arg;
	ctlr = edev->ctlr;
	while(waserror())
		;
	for(;;){
		s = mdior(ctlr, Bmsr);
		s = mdior(ctlr, Bmsr);		/* the link bit latches low */
		link = s > 0 && (s & Linkup) != 0 && (s & Andone) != 0;
		if(link != edev->nif.link){
			if(link)
				linkset(edev);
			else
				print("#l%d: rp1: link down\n", edev->ctlrno);
			edev->nif.link = link;
		}
		tsleep(&ctlr->lr, return0, nil, 500);
	}
}

static void
rxmode(Ether *edev, int prom)
{
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	if(prom)
		GEM(Ncfgr) |= Caf;
	else
		GEM(Ncfgr) &= ~Caf;
}

static void
prom(void *arg, int on)
{
	rxmode(arg, on);
}

static void
multi(void*, uchar*, int)
{
	/* every multicast is taken: the hash is all ones */
}

/*
 * The PHY's reset is RP1's GPIO 32, active low (the Pi 5's device tree):
 * bank 1 pin 4, by RIO, which is function 5.
 */
enum
{
	Gpio32ctrl	= 0xD4000 + 8*4 + 4,
	Gpio32pad	= 0xF4000 + 4 + 4*4,
	Rio1out		= 0xE4000,
	Rio1oe		= 0xE4004,
	Rioset		= 0x2000,
	Rioclr		= 0x3000,
	Pin		= 1<<4,
};

static void
phyreset(Ctlr *ctlr)
{
	RP1REG(Rio1oe + Rioset) = Pin;
	RP1REG(Rio1out + Rioclr) = Pin;
	RP1REG(Gpio32ctrl) = 5;
	RP1REG(Gpio32pad) = (RP1REG(Gpio32pad) | 1<<6) & ~(1<<7);	/* input on, output not disabled */
	tsleep(&ctlr->lr, return0, nil, 5);
	RP1REG(Rio1out + Rioset) = Pin;
	tsleep(&ctlr->lr, return0, nil, 150);
}

static void
attach(Ether *edev)
{
	Ctlr *ctlr;
	uchar *m;
	int i, nq, id;

	ctlr = edev->ctlr;
	qlock(&ctlr->alock);
	if(ctlr->attached){
		qunlock(&ctlr->alock);
		return;
	}
	if(waserror()){
		qunlock(&ctlr->alock);
		nexterror();
	}

	if((m = ctlr->tbuf) == nil){
		m = xspanalloc(Dmasize, Dmasize, 0);
		ctlr->rbuf = xspanalloc(Nrx*Bsz, BY2PG, 0);
		if(m == nil || ctlr->rbuf == nil)
			error(Enomem);
		if((uintptr)m + Dmasize > Dmalimit || (uintptr)ctlr->rbuf + Nrx*Bsz > Dmalimit)
			error("rp1: DMA memory above what RP1 can reach");
		cachedwbinvse(m, Dmasize);
		cachedwbinvse(ctlr->rbuf, Nrx*Bsz);
		mmunormalnc((uintptr)m, Dmasize);
	}
	memset(m, 0, Dmasize);
	ctlr->tbuf = m;
	ctlr->rx = (Desc*)(ctlr->tbuf + Ntx*Bsz);
	ctlr->tx = ctlr->rx + Nrx;
	ctlr->dummy = ctlr->tx + Ntx;


	GEM(Ncr) |= Thalt;
	for(i = 0; i < 100000 && (GEM(Tsr) & Tgo) != 0; i++)
		microdelay(1);
	GEM(Ncr) = Clrstat;
	GEM(Idr) = ~0;

	/* DCFG1 says 1, 2 or 4 words of 32 bits; NCFGR wants 0, 1 or 2 */
	i = (GEM(Dcfg1) >> 25) & 7;
	GEM(Ncfgr) = Mdcdiv96<<Mdcshift | (i >= 4 ? 2 : i >= 2 ? 1 : 0) << Dbwshift | Drfcs | Mti;
	GEM(Hrb) = ~0;
	GEM(Hrt) = ~0;
	GEM(Sa1b) = edev->ea[0] | edev->ea[1]<<8 | edev->ea[2]<<16 | edev->ea[3]<<24;
	GEM(Sa1t) = edev->ea[4] | edev->ea[5]<<8;

	for(i = 0; i < Nrx; i++){
		ctlr->rx[i].ctrl = 0;
		setaddr(&ctlr->rx[i], (uintptr)ctlr->rbuf + i*Bsz, i == Nrx-1 ? Rxwrap : 0);
	}
	for(i = 0; i < Ntx; i++){
		setaddr(&ctlr->tx[i], (uintptr)ctlr->tbuf + i*Bsz, 0);
		ctlr->tx[i].ctrl = Txused | (i == Ntx-1 ? Txwrap : 0);
	}
	ctlr->dummy->ctrl = Txused;
	setaddr(ctlr->dummy, (uintptr)ctlr->dummy, 0);
	coherence();

	GEM(Rbqp) = (u32int)(uintptr)ctlr->rx;
	GEM(Tbqp) = (u32int)(uintptr)ctlr->tx;
	GEM(Rbqph) = 0;
	GEM(Tbqph) = 0;
	GEM(Dmacfg) = (GEM(Dmacfg) & ~(0xFF<<Rxbsshift | 3<<6 | 0x1F)) |
		(Bsz/64)<<Rxbsshift | 16 | Txpbms | Rxbms | Addr64;

	nq = 1;
	for(i = 1; i < 8; i++)
		if(GEM(Dcfg6) & (1<<i))
			nq++;
	for(i = 0; i < nq-1; i++){
		ctlr->r[(Tbqpq + 4*i)/4] = (u32int)(uintptr)ctlr->dummy;
		ctlr->r[(Rbqpq + 4*i)/4] = (u32int)(uintptr)ctlr->dummy;
	}

	GEM(0x54) = 8 | 8<<8 | 1<<16;	/* AMP: rp1.dtsi's aw2w, ar2r and aw2b-fill */
	GEM(Usrio) = Rgmii;
	GEM(Ncr) = Mpe;
	phyreset(ctlr);
	ctlr->phy = -1;
	for(i = 0; i < 32 && ctlr->phy < 0; i++){
		ctlr->phy = i;
		if((id = mdior(ctlr, 2)) <= 0 || id == 0xFFFF)
			ctlr->phy = -1;
	}
	if(ctlr->phy < 0)
		error("rp1: no PHY answers");
	print("#l%d: rp1: phy%d id %.4ux %.4ux queues %d\n", edev->ctlrno,
		ctlr->phy, mdior(ctlr, 2), mdior(ctlr, 3), nq);
	if(cmdlineword("ether10")){
		mdiow(ctlr, Anar, 0x0061);
		mdiow(ctlr, Gtcr, 0);
	}else if(cmdlineword("ether100")){
		mdiow(ctlr, Anar, 0x01E1);
		mdiow(ctlr, Gtcr, 0);
	}else{
		mdiow(ctlr, Anar, 0x01E1);
		mdiow(ctlr, Gtcr, 3<<8);
	}
	mdiow(ctlr, Bmcr, 1<<12 | 1<<9);

	GEM(Intmod) = 50;
	rp1intrenable(RP1inteth, interrupt, edev, 1, "rp1eth");
	GEM(Ier) = Irxcomp | Itxcomp;
	GEM(Ncr) = Mpe | Txen | Rxen;

	ctlr->attached = 1;
	kproc("rp1-recv", recvproc, edev, 0);
	kproc("rp1-send", sendproc, edev, 0);
	kproc("rp1-link", linkproc, edev, 0);
	qunlock(&ctlr->alock);
	poperror();
}

static long
ifstat(Ether *edev, void *a, long n, ulong off)
{
	Ctlr *ctlr;
	char *p;

	ctlr = edev->ctlr;
	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	snprint(p, READSTR, "rp1 gem mid %#ux\nintr %lud rx %lud rxbad %lud tx %lud mdiotimeout %lud rxtail %d txhead %d\n"
		"tsr %#ux rsr %#ux isr %#ux ncfgr %#ux dmacfg %#ux\n"
		"mac txframes %ud txunder %ud rxframes %ud rxfcs %ud rxalign %ud rxover %ud rxres %ud\n",
		GEM(Mid), ctlr->nintr, ctlr->nrx, ctlr->nrxbad, ctlr->ntx, ctlr->nmdiotimeout, ctlr->rxtail, ctlr->txhead,
		GEM(Tsr), GEM(0x20), GEM(0x24), GEM(Ncfgr), GEM(Dmacfg),
		GEM(0x108), GEM(0x134), GEM(0x158), GEM(0x190), GEM(0x194), GEM(0x1A4), GEM(0x1A0));
	n = readstr(off, a, n, p);
	free(p);
	return n;
}

static void
shutdown(Ether *edev)
{
	Ctlr *ctlr;

	ctlr = edev->ctlr;
	GEM(Ncr) = 0;
}

void
etherrp1link(void)
{
	static Ctlr ctlr[1];
	Ether *edev;
	u32int mid;

	if(cmdlineword("noether")){
		print("rp1: Ethernet left off (noether)\n");
		return;
	}
	if(probe32(RP1ETH + Mid, &mid) < 0){
		print("rp1: no Ethernet MAC at %#llux\n", (uvlong)RP1ETH);
		return;
	}
	if(mid == 0 || mid == ~0U){
		print("rp1: Ethernet MAC id reads %#ux: not touching it\n", mid);
		return;
	}
	edev = etherinstance(0);
	if(edev == nil)
		return;
	if(getmacaddr(edev->ea) < 0){
		print("rp1: the firmware would not say what this board's MAC address is\n");
		return;
	}
	ctlr->r = (u32int*)(uintptr)RP1ETH;
	memmove(edev->nif.addr, edev->ea, Eaddrlen);
	edev->nif.alen = Eaddrlen;
	memset(edev->nif.bcast, 0xFF, Eaddrlen);
	edev->nif.mbps = 1000;
	edev->nif.link = 0;
	edev->nif.arg = edev;
	edev->nif.promiscuous = prom;
	edev->nif.multicast = multi;

	edev->ctlr = ctlr;
	edev->attach = attach;
	edev->transmit = transmit;
	edev->ifstat = ifstat;
	edev->shutdown = shutdown;
	print("rp1: GEM id %#ux %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux is #l (ether0)\n", mid,
		edev->ea[0], edev->ea[1], edev->ea[2], edev->ea[3], edev->ea[4], edev->ea[5]);
}
