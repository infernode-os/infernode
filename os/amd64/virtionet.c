/*
 * os/amd64/virtionet.c -- virtio-net over PCI, polled.
 *
 * QEMU's virtio-net-pci and 9vm's NIC are both the modern (1.0) virtio
 * PCI transport: a memory BAR holding a common configuration block,
 * a doorbell, an ISR byte and the device's own configuration.  The
 * capability list says where each lives, in which BAR and at what
 * offset, so one driver finds the device under either loader.
 *
 * These are the first PCI devices this kernel has driven, so this file
 * also carries the parts of a PCI bus a driver needs and nothing more:
 * the configuration pair at 0xCF8/0xCFC (pci.c), a BAR mapped into the
 * identity map (mmiomap), and the capability walk.
 *
 * Receive is interrupt-driven: the device's INTx line (11, as the PCI
 * config says) is unmasked, trap.c dispatches it, and the handler
 * reads the ISR byte -- which is what deasserts the line -- then wakes
 * the receive kproc.  The work itself (allocb, etheriqb) is not
 * something an interrupt may do here.  The kproc still wakes on a
 * 100ms timeout as a safety net, so a lost interrupt delays a frame
 * rather than losing it.
 *
 * The other difference from the MMIO transport in os/virtio is the
 * header: a modern virtio-net buffer begins with twelve bytes of
 * virtio_net_hdr (ten on the legacy transport).  None of the offloads
 * are negotiated, so it is zeroes going out and ignored coming in; its
 * length is the only thing that matters.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "../port/netif.h"
#include "../port/etherif.h"
#include "port.h"

enum
{
	Pcivendor	= 0x1AF4,
	Pcidevnet	= 0x1041,	/* modern virtio-net */

	Capvendor	= 0x09,
	Capcommon	= 1,
	Capnotify	= 2,
	Capisr		= 3,
	Capdevice	= 4,

	/* common configuration, std virtio 1.0 offsets */
	Cdevfeatsel	= 0x00,
	Cdevfeat	= 0x04,
	Cdrvfeatsel	= 0x08,
	Cdrvfeat	= 0x0C,
	Cstatus		= 0x14,
	Cqsel		= 0x16,
	Cqsize		= 0x18,
	Cqenable	= 0x1C,
	Cqnotifyoff	= 0x1E,
	Cqdesc		= 0x20,
	Cqavail		= 0x28,
	Cqused		= 0x30,

	Netfmac		= 1ULL<<5,
	Netfstatus	= 1ULL<<16,
	Vfversion1	= 1ULL<<32,

	Sack		= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeaturesok	= 8,

	Qrx		= 0,
	Qtx		= 1,
	Nq		= 64,
	Hdr		= 12,		/* virtio_net_hdr, modern */
	Framemax	= 1514,
	Pollms		= 100,		/* safety-net wakeup; an interrupt is immediate */

	Vdwrite		= 1<<1,		/* the device writes this buffer */
};

typedef struct Vqdesc Vqdesc;
struct Vqdesc
{
	uint64_t	addr;
	uint32_t	len;
	uint16_t	flags;
	uint16_t	next;
};

typedef struct Vqusedelem Vqusedelem;
struct Vqusedelem
{
	uint32_t	id;
	uint32_t	len;
};

typedef struct Vqused Vqused;
struct Vqused
{
	uint16_t	flags;
	uint16_t	idx;
	Vqusedelem	ring[1];	/* Nq of them, allocated */
};

#define	AVAILSZ(n)	(4 + 2*(n) + 2)
#define	USEDSZ(n)	(4 + 8*(n))

typedef struct Ctlr Ctlr;
struct Ctlr
{
	Ether		*edev;
	int		dev, fn;
	uchar		*common;
	uchar		*notify;
	uchar		*isr;		/* mapped for the interrupt stage */
	uchar		*devcfg;
	uint32_t	notifymult;
	uint64_t	feats;

	Vqdesc		*rxdesc;
	Vqused		*rxused;
	uint16_t	*rxavail;
	uint16_t	rxqsize;	/* the device's ring size */
	uint16_t	rxn;		/* descriptors we actually use */
	uint16_t	rxlast;
	uint16_t	rxnotify;
	Block		*rxb[Nq];

	Vqdesc		*txdesc;
	Vqused		*txused;
	uint16_t	*txavail;
	uint16_t	txqsize;
	uint16_t	txn;
	uint16_t	txlast;
	uint16_t	txnotify;
	Block		*txb[Nq];
	int		txinuse[Nq];

	Lock		l;
	int		started;
	int		irq;
	int		work;		/* an interrupt happened */
	int		saidintr;
	Rendez		r;
	ulong		nintr;
	ulong		nrx, ntx, ntxdone, nrxdrop, ntxfull, nrefill;
};

static Ctlr ctlr;

static void	netlink(Ctlr*);

/*
 * The register accessors name the one controller.  A second card is a
 * second Ctlr and these become parameters; the device table and /net
 * already have room for it (ether1, #l1).
 */
#define	C8(o)	(*(volatile uint8_t*)(ctlr.common + (o)))
#define	C16(o)	(*(volatile uint16_t*)(ctlr.common + (o)))
#define	C32(o)	(*(volatile uint32_t*)(ctlr.common + (o)))

static int
baraddr(int dev, int fn, int bar, uint64_t *pa)
{
	uint32_t v;

	if(bar < 0 || bar > 5)
		return -1;
	v = pcicfgr32(0, dev, fn, 0x10 + 4*bar);
	if(v & 1)
		return -1;		/* an I/O BAR is not the modern transport */
	*pa = v & ~0xFULL;
	if((v & 0x4) && bar < 5)
		*pa |= (uint64_t)pcicfgr32(0, dev, fn, 0x10 + 4*(bar+1)) << 32;
	return 0;
}

/*
 * Walk the capability list for the four vendor capabilities the modern
 * transport is made of.  Each is: id 0x09, next, len, cfg_type, bar,
 * offset (u32), length (u32), and for notify only, a multiplier (u32).
 */
static int
findcaps(int dev, int fn, Ctlr *c)
{
	uint8_t ptr;
	uint64_t pa;
	uint32_t off, len;
	int i, id, type, bar;

	if((pcicfgr16(0, dev, fn, 0x06) & 0x10) == 0)
		return -1;
	ptr = pcicfgr8(0, dev, fn, 0x34) & ~3;
	for(i = 0; ptr != 0 && i < 48; i++){
		id = pcicfgr8(0, dev, fn, ptr);
		if(id == Capvendor){
			type = pcicfgr8(0, dev, fn, ptr+3);
			bar = pcicfgr8(0, dev, fn, ptr+4);
			off = pcicfgr32(0, dev, fn, ptr+8);
			len = pcicfgr32(0, dev, fn, ptr+12);
			switch(type){
			case Capcommon:
				if(baraddr(dev, fn, bar, &pa) < 0)
					return -1;
				c->common = mmiomap(pa, len);
				break;
			case Capnotify:
				c->notifymult = 0;
				if(ptr + 16 < 256 && pcicfgr8(0, dev, fn, ptr+2) >= 20)
					c->notifymult = pcicfgr32(0, dev, fn, ptr+16);
				if(baraddr(dev, fn, bar, &pa) < 0)
					return -1;
				c->notify = mmiomap(pa + off, len);
				break;
			case Capisr:
				if(baraddr(dev, fn, bar, &pa) < 0)
					return -1;
				c->isr = mmiomap(pa + off, len);
				break;
			case Capdevice:
				if(baraddr(dev, fn, bar, &pa) < 0)
					return -1;
				c->devcfg = mmiomap(pa + off, len);
				break;
			}
		}
		ptr = pcicfgr8(0, dev, fn, ptr+1) & ~3;
	}
	return (c->common != nil && c->notify != nil && c->devcfg != nil) ? 0 : -1;
}

static int
finddev(Ctlr *c)
{
	uint32_t id;
	int dev, fn;

	for(dev = 0; dev < 32; dev++)
	for(fn = 0; fn < 8; fn++){
		id = pcicfgr32(0, dev, fn, 0);
		if((id & 0xFFFF) == 0xFFFF)
			continue;
		if((id & 0xFFFF) == Pcivendor && (id >> 16) == Pcidevnet){
			c->dev = dev;
			c->fn = fn;
			return findcaps(dev, fn, c);
		}
	}
	return -1;
}

static void
addavail(uint16_t *avail, int n, uint16_t head)
{
	uint16_t idx;

	idx = avail[1];
	avail[2 + idx % n] = head;
	coherence();
	avail[1] = idx + 1;
}

static void
kick(Ctlr *c, int q, uint16_t notifyoff)
{
	*(volatile uint16_t*)(c->notify + (uint64_t)notifyoff * c->notifymult) = q;
}

static int
rxpost(Ctlr *c, int i)
{
	Block *b;

	b = allocb(Hdr + Framemax + 4);
	if(b == nil)
		return -1;
	c->rxb[i] = b;
	c->rxdesc[i].addr = PADDR(b->rp);
	c->rxdesc[i].len = Hdr + Framemax + 4;
	c->rxdesc[i].flags = Vdwrite;
	c->rxdesc[i].next = 0;
	return 0;
}

static void
rxproc(Ctlr *c)
{
	uint16_t idx;
	uint32_t i, len;
	Vqusedelem *e;
	Block *b;
	int posted;

	posted = 0;
	coherence();
	idx = c->rxused->idx;
	while(c->rxlast != idx){
		e = &c->rxused->ring[c->rxlast % c->rxqsize];
		i = e->id;
		len = e->len;
		c->rxlast++;
		if(i >= c->rxn)
			continue;
		b = c->rxb[i];
		c->rxb[i] = nil;
		if(b != nil){
			if(len > Hdr && len <= Hdr + Framemax + 4){
				b->rp += Hdr;
				b->wp = b->rp + (len - Hdr);
				c->nrx++;
				etheriqb(c->edev, b);
			}else{
				freeb(b);
				c->nrxdrop++;
			}
		}
		if(rxpost(c, i) == 0){
			addavail(c->rxavail, c->rxqsize, i);
			posted = 1;
		}
	}
	if(posted)
		kick(c, Qrx, c->rxnotify);
}

static int
txfree(Ctlr *c)
{
	int i;

	for(i = 0; i < c->txn; i++)
		if(!c->txinuse[i])
			return i;
	return -1;
}

static void
txreap(Ctlr *c)
{
	uint16_t idx;
	Vqusedelem *e;
	uint32_t i;

	coherence();
	idx = c->txused->idx;
	while(c->txlast != idx){
		e = &c->txused->ring[c->txlast % c->txqsize];
		i = e->id;
		c->txlast++;
		if(i >= c->txn || !c->txinuse[i])
			continue;
		if(c->txb[i] != nil)
			freeb(c->txb[i]);
		c->txb[i] = nil;
		c->txinuse[i] = 0;
		c->ntxdone++;
	}
}

/*
 * devether calls this after putting frames on e->oq.  A frame the ring
 * has no descriptor for stays on the queue and the poller tries again.
 */
static void
nettransmit(Ether *e)
{
	Ctlr *c;
	Block *b;
	int i, kicked;

	c = e->ctlr;
	if(c == nil || !c->started)
		return;
	kicked = 0;
	ilock(&c->l);
	txreap(c);
	while((i = txfree(c)) >= 0){
		b = qget(e->oq);
		if(b == nil)
			break;
		b = padblock(b, Hdr);
		if(b == nil)
			break;
		memset(b->rp, 0, Hdr);
		c->txdesc[i].addr = PADDR(b->rp);
		c->txdesc[i].len = BLEN(b);
		c->txdesc[i].flags = 0;
		c->txdesc[i].next = 0;
		c->txb[i] = b;
		c->txinuse[i] = 1;
		coherence();
		addavail(c->txavail, c->txqsize, i);
		c->ntx++;
		e->nif.outpackets++;
		kicked = 1;
	}
	if(qlen(e->oq) > 0)
		c->ntxfull++;
	iunlock(&c->l);
	if(kicked)
		kick(c, Qtx, c->txnotify);
}

static int
network(void *a)
{
	return ((Ctlr*)a)->work != 0;
}

/*
 * Interrupt context.  Reading the ISR byte is what deasserts the
 * device's INTx line, and it must happen here rather than after the
 * EOI in trap.c; the receive work itself (allocb, etheriqb) is not
 * something an interrupt may do, so it wakes the poller instead.
 */
static void
netintr(void *a)
{
	Ctlr *c;

	c = a;
	if(c->isr[0] & 1)
		c->nintr++;
	c->work = 1;
	wakeup(&c->r);
}

static void
netproc(void *a)
{
	Ctlr *c;
	ulong ticks;

	c = a;
	ticks = 0;
	for(;;){
		rxproc(c);
		ilock(&c->l);
		txreap(c);
		iunlock(&c->l);
		nettransmit(c->edev);
		if(c->nintr != 0 && !c->saidintr){
			c->saidintr = 1;
			print("ether: virtio-net interrupt-driven (irq %d)\n", c->irq);
		}
		if(++ticks % 100 == 0)
			netlink(c);
		if(c->work)
			c->work = 0;
		else
			/*
			 * The interrupt wakes this at once.  The timeout is
			 * the safety net for a lost or spurious one, and is
			 * what makes the driver work before any has been
			 * seen.
			 */
			tsleep(&c->r, network, c, Pollms);
	}
}

static void
netattach(Ether *e)
{
	Ctlr *c;

	c = e->ctlr;
	ilock(&c->l);
	if(c->started){
		iunlock(&c->l);
		return;
	}
	c->started = 1;
	iunlock(&c->l);
	kproc("virtio-net", netproc, c, 0);
}

static void
netlink(Ctlr *c)
{
	uchar st[2];

	if((c->feats & Netfstatus) == 0)
		return;
	st[0] = c->devcfg[6];
	st[1] = c->devcfg[7];
	c->edev->nif.link = (st[0] | st[1]<<8) & 1;
}

static long
vnetifstat(Ether *e, void *a, long n, ulong off)
{
	Ctlr *c;
	char *p;

	c = e->ctlr;
	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	if(waserror()){
		free(p);
		nexterror();
	}
	snprint(p, READSTR,
		"virtio-net pci %d:%d.%d modern transport, header %d bytes\n"
		"intr %lud rx %lud tx %lud txdone %lud rxdrop %lud txfull %lud refill %lud\n"
		"rxidx %ud/%ud txidx %ud/%ud\n",
		c->dev, c->fn, 0, Hdr, c->nintr, c->nrx, c->ntx, c->ntxdone,
		c->nrxdrop, c->ntxfull, c->nrefill,
		c->rxlast, c->rxused->idx, c->txlast, c->txused->idx);
	n = readstr(off, a, n, p);
	free(p);
	poperror();
	return n;
}

/*
 * Set up the queues and negotiate features.  Every address the device
 * is given is physical; this port's map is the identity, so PADDR is a
 * cast, but it is written wherever a pointer crosses to the device.
 */
static int
startdev(Ctlr *c)
{
	uint32_t f0, f1;
	uint16_t n;
	uint64_t pa;

	C8(Cstatus) = 0;
	coherence();

	C8(Cstatus) = Sack | Sdriver;

	C32(Cdevfeatsel) = 0;
	f0 = C32(Cdevfeat);
	C32(Cdevfeatsel) = 1;
	f1 = C32(Cdevfeat);
	c->feats = (uint64_t)f1 << 32 | f0;

	C32(Cdrvfeatsel) = 0;
	C32(Cdrvfeat) = f0 & (Netfmac | Netfstatus);
	C32(Cdrvfeatsel) = 1;
	C32(Cdrvfeat) = f1 & (Vfversion1 >> 32);
	coherence();

	C8(Cstatus) = Sack | Sdriver | Sfeaturesok;
	if((C8(Cstatus) & Sfeaturesok) == 0)
		return -1;

	/* receive queue */
	C16(Cqsel) = Qrx;
	n = C16(Cqsize);
	if(n < 2)
		return -1;
	if(n > 256)
		n = 256;
	c->rxqsize = n;
	c->rxn = n > Nq ? Nq : n;
	c->rxdesc = xallocz(n*sizeof(Vqdesc), 1);
	c->rxavail = xallocz(AVAILSZ(n), 1);
	c->rxused = xallocz(USEDSZ(n), 1);
	if(c->rxdesc == nil || c->rxavail == nil || c->rxused == nil)
		return -1;
	pa = PADDR(c->rxdesc);
	C32(Cqdesc) = pa;
	C32(Cqdesc+4) = pa >> 32;
	pa = PADDR(c->rxavail);
	C32(Cqavail) = pa;
	C32(Cqavail+4) = pa >> 32;
	pa = PADDR(c->rxused);
	C32(Cqused) = pa;
	C32(Cqused+4) = pa >> 32;
	coherence();
	C16(Cqenable) = 1;
	c->rxnotify = C16(Cqnotifyoff);

	/* transmit queue */
	C16(Cqsel) = Qtx;
	n = C16(Cqsize);
	if(n < 2)
		return -1;
	if(n > 256)
		n = 256;
	c->txqsize = n;
	c->txn = n > Nq ? Nq : n;
	c->txdesc = xallocz(n*sizeof(Vqdesc), 1);
	c->txavail = xallocz(AVAILSZ(n), 1);
	c->txused = xallocz(USEDSZ(n), 1);
	if(c->txdesc == nil || c->txavail == nil || c->txused == nil)
		return -1;
	pa = PADDR(c->txdesc);
	C32(Cqdesc) = pa;
	C32(Cqdesc+4) = pa >> 32;
	pa = PADDR(c->txavail);
	C32(Cqavail) = pa;
	C32(Cqavail+4) = pa >> 32;
	pa = PADDR(c->txused);
	C32(Cqused) = pa;
	C32(Cqused+4) = pa >> 32;
	coherence();
	C16(Cqenable) = 1;
	c->txnotify = C16(Cqnotifyoff);

	C8(Cstatus) = Sack | Sdriver | Sfeaturesok | Sdriverok;
	return 0;
}

static void
fillrx(Ctlr *c)
{
	int i, posted;

	posted = 0;
	for(i = 0; i < c->rxn; i++){
		if(rxpost(c, i) < 0)
			break;
		addavail(c->rxavail, c->rxqsize, i);
		posted = 1;
	}
	if(posted)
		kick(c, Qrx, c->rxnotify);
	c->nrefill += i;
}

void
virtionetlink(void)
{
	Ctlr *c;
	Ether *e;
	int i;

	c = &ctlr;
	if(c->started)
		return;
	if(finddev(c) < 0)
		return;		/* not an error: the machine may have no card */
	print("ether: virtio-net at pci %d:%d.%d common %p notify %p devcfg %p\n",
		c->dev, c->fn, 0, c->common, c->notify, c->devcfg);
	e = etherinstance(0);
	if(e == nil)
		return;

	/* memory space and bus mastership: the device reads the rings */
	pciwrite16(0, c->dev, c->fn, 0x04,
		pcicfgr16(0, c->dev, c->fn, 0x04) | 0x6);

	c->irq = pcicfgr8(0, c->dev, c->fn, 0x3C);
	print("ether: virtio-net irq %d\n", c->irq);
	if(startdev(c) < 0){
		print("ether: virtio-net at %d:%d.%d did not start\n", c->dev, c->fn);
		return;
	}
	fillrx(c);
	intrenable(c->irq, netintr, c, "virtio-net");

	if(c->feats & Netfmac)
		for(i = 0; i < Eaddrlen; i++)
			e->ea[i] = c->devcfg[i];
	else {
		e->ea[0] = 0x52; e->ea[1] = 0x54; e->ea[2] = 0x00;
		e->ea[3] = 0x12; e->ea[4] = 0x34; e->ea[5] = 0x56;
	}
	memmove(e->nif.addr, e->ea, Eaddrlen);
	e->nif.alen = Eaddrlen;
	memset(e->nif.bcast, 0xFF, Eaddrlen);
	e->nif.mbps = 1000;
	e->nif.link = 1;

	c->edev = e;
	e->ctlr = c;
	e->attach = netattach;
	e->transmit = nettransmit;
	e->ifstat = vnetifstat;
	netlink(c);

	print("ether: virtio-net %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux is #l (ether0)\n",
		e->ea[0], e->ea[1], e->ea[2], e->ea[3], e->ea[4], e->ea[5]);
}
