/*
 * The network card: a virtio net device, as /net/ether0.
 *
 * On the board, wired Ethernet is a LAN7515 on the far side of a USB
 * hub, and getting a frame to it takes a host-controller driver, split
 * transactions, a class driver in Limbo and a record format wrapped
 * round every packet; devether.c's instance 0 is where all of that
 * lands. QEMU's Raspberry Pi model has no network card at all, so under
 * emulation the board's kernel has only ever been given a USB one.
 *
 * Here a frame is a buffer on a virtio queue. This file fills in
 * devether's vtable for instance 0 -- the way the radio driver
 * (os/bcm/ether4330.c) fills in instance 1 -- so that what the rest
 * of the system sees is exactly what it sees on the board: #l is
 * ether0, /net/ether0 has an addr and a clone, ethermedium binds it by
 * name. Everything above the driver -- os/ip, DHCP, 9P over TCP, TLS --
 * runs at the speed of the host and with none of the USB stack under
 * it, which is what makes it possible to tell "os/ip is slow" from
 * "the bus is slow".
 *
 *	-netdev user,id=n0 -device virtio-net-device,netdev=n0
 *
 * Two queues: 0 receives, 1 transmits. Every buffer in either begins
 * with a header virtio defines for offloads -- checksums the host could
 * finish, segments it could split. None is negotiated here, so the
 * header is zeroes going out and ignored coming in, and the only thing
 * about it that matters is its LENGTH: ten bytes on a legacy transport,
 * twelve on a modern one. Get that wrong and every frame arrives two
 * bytes out of place, which looks like a checksum problem and is not.
 *
 * Receive: the queue is kept full of empty Blocks. The device fills
 * one and interrupts; the interrupt wakes a kproc; the kproc takes the
 * Block off the used ring, steps over the header, hands it to
 * etheriqb, and posts a fresh one. A kproc and not the interrupt
 * handler because etheriqb may copy a Block for a second reader, and
 * allocating is not something an interrupt may do here.
 *
 * Transmit: a Block from devether's output queue grows a header in the
 * space allocb leaves in front of every Block for exactly this
 * (padblock, no copy), and is queued as one buffer. It stays the
 * device's until it comes back on the used ring, where it is freed --
 * by the next transmit, or by the kproc when the transmit interrupt
 * says something finished, whichever is first. If the queue is full
 * the frame waits on the output queue for one of those.
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
#include "virtio.h"

enum
{
	Netfmac		= 1ULL<<5,	/* the device has an address to read */

	Rxq		= 0,
	Txq		= 1,
	Nrx		= 128,		/* receive buffers kept posted */
	Ntx		= 128,

	Hdrlegacy	= 10,
	Hdrmodern	= 12,		/* the same, plus a buffer count we never use */

	Framemax	= 1514,
};

typedef struct Ctlr Ctlr;
struct Ctlr
{
	Vdev	*dev;
	Vq	*rx;
	Vq	*tx;
	Ether	*edev;
	int	hdrlen;
	int	started;

	QLock	tlock;		/* one transmitter at a time */
	Rendez	r;
	int	work;		/* an interrupt happened */

	ulong	nintr, nrx, ntx, nrxdrop, ntxfull, nrefill;
};

static Ctlr ctlr;

static void
netinterrupt(Ureg*, void *a)
{
	Ctlr *c;

	c = a;
	if(virtiointr(c->dev) & 1){
		c->nintr++;
		c->work = 1;
		wakeup(&c->r);
	}
}

static int
network(void *a)
{
	return ((Ctlr*)a)->work;
}

/* post one empty Block to the receive queue; 0 if there was no room or no memory */
static int
rxpost(Ctlr *c)
{
	Block *b;
	Vbuf v;

	if(vqroom(c->rx) == 0)
		return 0;
	b = allocb(c->hdrlen + Framemax + 4);
	if(b == nil)
		return 0;
	v.p = b->wp;
	v.len = c->hdrlen + Framemax + 4;
	v.write = 1;
	if(vqsubmit(c->rx, &v, 1, b) < 0){
		freeb(b);
		return 0;
	}
	return 1;
}

/* free what the device has finished sending */
static void
txreap(Ctlr *c)
{
	void *cookie;

	while(vqcollect(c->tx, nil, &cookie) >= 0)
		if(cookie != nil)
			freeb(cookie);
}

/*
 * devether calls this after putting a frame on e->oq; the kproc calls
 * it after a completion, for frames that found the queue full.
 */
static void
nettransmit(Ether *e)
{
	Ctlr *c;
	Block *b;
	Vbuf v;
	int kicked;

	c = e->ctlr;
	if(c == nil || !c->started)
		return;
	kicked = 0;
	qlock(&c->tlock);
	txreap(c);
	while(vqroom(c->tx) > 0 && (b = qget(e->oq)) != nil){
		b = padblock(b, c->hdrlen);
		memset(b->rp, 0, c->hdrlen);
		v.p = b->rp;
		v.len = BLEN(b);
		v.write = 0;
		if(vqsubmit(c->tx, &v, 1, b) < 0){
			freeb(b);
			e->nif.oerrs++;
			break;
		}
		c->ntx++;
		e->nif.outpackets++;
		kicked = 1;
	}
	if(qlen(e->oq) > 0)
		c->ntxfull++;
	qunlock(&c->tlock);
	if(kicked)
		vqkick(c->tx);
}

static void
netproc(void *a)
{
	Ctlr *c;
	Ether *e;
	Block *b;
	void *cookie;
	u32int len;
	int posted;

	c = a;
	e = c->edev;
	for(;;){
		sleep(&c->r, network, c);
		c->work = 0;

		posted = 0;
		while(vqcollect(c->rx, &len, &cookie) >= 0){
			b = cookie;
			if(b == nil)
				continue;
			if(len <= (u32int)c->hdrlen || len > (u32int)(c->hdrlen + Framemax + 4)){
				c->nrxdrop++;
				freeb(b);
			}else{
				b->rp += c->hdrlen;
				b->wp = b->rp + (len - c->hdrlen);
				c->nrx++;
				etheriqb(e, b);
			}
			posted += rxpost(c);
		}
		/* and any the queue is short of from an earlier failed allocation */
		while(rxpost(c)){
			posted++;
			c->nrefill++;
		}
		if(posted)
			vqkick(c->rx);

		nettransmit(e);
	}
}

/*
 * Runs in the process that binds #l, once. The queues were set up at
 * link time; what waits until now is what needs a process context: the
 * kproc, and telling the device to start.
 */
static void
netattach(Ether *e)
{
	Ctlr *c;
	int i;

	c = e->ctlr;
	qlock(&c->tlock);
	if(c->started){
		qunlock(&c->tlock);
		return;
	}
	for(i = 0; i < Nrx; i++)
		if(!rxpost(c))
			break;
	intrenable(c->dev->irq, netinterrupt, c, 0, "virtio-net");
	virtioready(c->dev);
	vqkick(c->rx);
	c->started = 1;
	qunlock(&c->tlock);
	kproc("virtio-net", netproc, c, 0);
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
	snprint(p, READSTR,
		"virtio-net slot %d irq %d %s transport, header %d bytes\n"
		"intrs %lud rx %lud tx %lud rxdrop %lud txfull %lud refill %lud\n"
		"rxroom %d txroom %d oq %d\n",
		c->dev->slot, c->dev->irq, c->dev->legacy ? "legacy" : "modern", c->hdrlen,
		c->nintr, c->nrx, c->ntx, c->nrxdrop, c->ntxfull, c->nrefill,
		vqroom(c->rx), vqroom(c->tx), qlen(e->oq));
	n = readstr(off, a, n, p);
	free(p);
	return n;
}

/*
 * Called from boarddevprobe, after devether's reset has made instance 0
 * and before anything can bind #l. Without a card on the command line
 * instance 0 is left as it was, an ether0 waiting for a USB bind that
 * this machine cannot supply: /net/ether0 exists and is dead, and
 * osinit says there is no network, which is true.
 */
void
ethervirtiolink(void)
{
	Ctlr *c;
	Ether *e;

	c = &ctlr;
	c->dev = virtiofind(Vidnet, 0);
	if(c->dev == nil){
		print("ether: no virtio network card\n");
		return;
	}
	e = etherinstance(0);
	if(e == nil)
		return;
	if(virtiostart(c->dev, Netfmac) < 0)
		return;
	c->hdrlen = c->dev->legacy ? Hdrlegacy : Hdrmodern;
	c->rx = virtioqueue(c->dev, Rxq, Nrx);
	c->tx = virtioqueue(c->dev, Txq, Ntx);
	if(c->rx == nil || c->tx == nil){
		virtiofail(c->dev);
		return;
	}

	if(c->dev->features & Netfmac)
		virtiocfgread(c->dev, 0, e->ea, Eaddrlen);
	else{
		/* QEMU always offers one; this is its own default, for form */
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

	print("ether: virtio-net %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux is #l (ether0)\n",
		e->ea[0], e->ea[1], e->ea[2], e->ea[3], e->ea[4], e->ea[5]);
}
