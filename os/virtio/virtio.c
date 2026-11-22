/*
 * virtio over MMIO: the transport, and the queues.
 *
 * virtio is how a guest talks to devices that exist only in its host:
 * a network card, a disk, a source of random numbers, none of them
 * modelled on any hardware. Every one of them works the same way, which
 * is the point. The guest and the device share a QUEUE -- three arrays
 * in the guest's memory -- and everything either side ever says to the
 * other is a buffer passed through one:
 *
 *   the DESCRIPTOR table	"here is a buffer": address, length,
 *				whether the device reads or writes it, and
 *				optionally the index of the next piece, so
 *				a request can be a chain of several
 *   the AVAILABLE ring		guest to device: heads of chains the
 *				device may now process
 *   the USED ring		device to guest: heads of chains it has
 *				finished, and how much it wrote
 *
 * The guest fills in descriptors, puts the head in the available ring,
 * and writes the queue's number to a doorbell register. The device
 * does the work, puts the head in the used ring, and raises an
 * interrupt. A driver is therefore: what goes in the buffers. That is
 * why the four drivers here are short.
 *
 * What is memory-mapped is only the TRANSPORT: a page of registers per
 * device, for finding out what the device is, agreeing on features,
 * telling it where the queue's three arrays are, and the doorbell.
 * virt has thirty-two of them at VIRTIOREGS, 0x200 apart, each with
 * its own interrupt; QEMU fills them from the command line, one per
 * "-device virtio-*-device", and an empty one reports device id zero.
 * THEY FILL FROM THE TOP: the first device on the command line is in
 * slot 31. A scan that stops at the first empty slot finds nothing.
 *
 * TWO VERSIONS of the transport exist and QEMU's default is the old
 * one. A "legacy" (version 1) transport is told where a queue is by
 * page number, and the three arrays must be laid out in one contiguous
 * block in a fixed arrangement; a modern (version 2) transport takes
 * three independent 64-bit addresses, and insists that the driver
 * accept the VERSION_1 feature and confirm the negotiation before it
 * will run. QEMU gives a modern one only when asked
 * (-global virtio-mmio.force-legacy=false). This file lays every queue
 * out the legacy way -- which is also a perfectly good modern layout --
 * so that one allocation serves both, and the two differ only in which
 * registers the addresses are written to.
 *
 * Addresses given to a device are PHYSICAL. The kernel's map is the
 * identity (mmu.c), so PADDR is a cast, but it is written wherever a
 * pointer crosses to the device so that the day the map changes this
 * file already says where it matters.
 *
 * Caches: under QEMU's TCG there are none, and under KVM the device is
 * a host thread reading the same physical memory through the same
 * coherent hierarchy the guest's cores share; either way a store is
 * visible to the device once it is visible to another core. So there
 * is no cache maintenance here, unlike every DMA path on the board --
 * only barriers (coherence()) where the ORDER of stores matters.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "virtio.h"

enum
{
	/* transport registers */
	Vrmagic		= 0x000,	/* "virt" */
	Vrversion	= 0x004,	/* 1 legacy, 2 modern */
	Vrdeviceid	= 0x008,	/* 0: nothing in this slot */
	Vrvendorid	= 0x00C,
	Vrdevfeat	= 0x010,
	Vrdevfeatsel	= 0x014,
	Vrdrvfeat	= 0x020,
	Vrdrvfeatsel	= 0x024,
	Vrguestpagesz	= 0x028,	/* legacy */
	Vrqsel		= 0x030,
	Vrqnummax	= 0x034,
	Vrqnum		= 0x038,
	Vrqalign	= 0x03C,	/* legacy */
	Vrqpfn		= 0x040,	/* legacy */
	Vrqready	= 0x044,	/* modern */
	Vrqnotify	= 0x050,	/* the doorbell */
	Vrintstatus	= 0x060,
	Vrintack	= 0x064,
	Vrstatus	= 0x070,
	Vrqdesclo	= 0x080,	/* modern, and the five after it */
	Vrqdeschi	= 0x084,
	Vrqavaillo	= 0x090,
	Vrqavailhi	= 0x094,
	Vrqusedlo	= 0x0A0,
	Vrqusedhi	= 0x0A4,
	Vrconfig	= 0x100,	/* the device's own configuration */

	Magic		= 0x74726976,

	/* Vrstatus */
	Sack		= 1<<0,		/* "I see a device" */
	Sdriver		= 1<<1,		/* "and I know how to drive it" */
	Sdriverok	= 1<<2,		/* "go" */
	Sfeaturesok	= 1<<3,		/* modern: "that is my final offer" */
	Sneedsreset	= 1<<6,
	Sfailed		= 1<<7,

	Qalign		= BY2PG,
};

#define REG(d, r)	(*(volatile u32int*)((d)->regs + (r)))

static Vdev vdevs[Nvirtio];
static int nvdev;

/*
 * Find what is in the slots. Called once, from boardioprobe; drivers
 * then ask for their device by kind with virtiofind.
 */
void
virtioscan(void)
{
	Vdev *d;
	uintptr regs;
	u32int id;
	int i;

	nvdev = 0;
	for(i = 0; i < Nvirtio; i++){
		regs = VIRTIOREGS + i*Virtiostride;
		if(*(volatile u32int*)(regs + Vrmagic) != Magic)
			continue;
		id = *(volatile u32int*)(regs + Vrdeviceid);
		if(id == 0)
			continue;		/* empty, and most are */
		d = &vdevs[nvdev++];
		memset(d, 0, sizeof *d);
		d->slot = i;
		d->regs = regs;
		d->irq = IRQvirtio0 + i;
		d->id = id;
		d->legacy = REG(d, Vrversion) < 2;
		print("virtio: slot %d irq %d: device %d (%s), %s transport\n",
			i, d->irq, id,
			id == Vidnet ? "network" :
			id == Vidblk ? "block" :
			id == Vidrng ? "entropy" :
			id == Vidgpu ? "gpu" :
			id == Vidinput ? "input" : "no driver here",
			d->legacy ? "legacy" : "modern");
	}
	if(nvdev == 0)
		print("virtio: no devices. They are given on QEMU's command line: -device virtio-rng-device ...\n");
}

/*
 * The nth device of a kind, in COMMAND LINE order. Slots fill from the
 * top, so the scan's order is the reverse of the order they were
 * asked for in, and "the first disk" should mean the first one named.
 */
Vdev*
virtiofind(int id, int nth)
{
	int i;

	for(i = nvdev-1; i >= 0; i--)
		if(vdevs[i].id == id && nth-- == 0)
			return &vdevs[i];
	return nil;
}

/*
 * Reset the device and agree on features: `want` is what the driver
 * can use, the result (in d->features) is what the device also offers.
 * Returns -1 if the device will not have it.
 *
 * The order is the specification's and the device enforces it: reset,
 * ACKNOWLEDGE, DRIVER, features, FEATURES_OK and check it stuck (modern
 * only), then queues, then DRIVER_OK from virtioready.
 */
int
virtiostart(Vdev *d, u64int want)
{
	u64int offered;

	REG(d, Vrstatus) = 0;
	coherence();
	REG(d, Vrstatus) = Sack;
	REG(d, Vrstatus) = Sack|Sdriver;

	REG(d, Vrdevfeatsel) = 0;
	offered = REG(d, Vrdevfeat);
	if(!d->legacy){
		REG(d, Vrdevfeatsel) = 1;
		offered |= (u64int)REG(d, Vrdevfeat) << 32;
		want |= Vfversion1;
	}
	d->features = offered & want;

	REG(d, Vrdrvfeatsel) = 0;
	REG(d, Vrdrvfeat) = (u32int)d->features;
	if(d->legacy){
		/* a legacy queue is found by page number; say how big a page is */
		REG(d, Vrguestpagesz) = BY2PG;
		return 0;
	}
	REG(d, Vrdrvfeatsel) = 1;
	REG(d, Vrdrvfeat) = (u32int)(d->features >> 32);

	REG(d, Vrstatus) = Sack|Sdriver|Sfeaturesok;
	coherence();
	if((REG(d, Vrstatus) & Sfeaturesok) == 0){
		print("virtio: slot %d refused features %#llux\n", d->slot, d->features);
		virtiofail(d);
		return -1;
	}
	return 0;
}

void
virtiofail(Vdev *d)
{
	REG(d, Vrstatus) = REG(d, Vrstatus) | Sfailed;
}

void
virtioready(Vdev *d)
{
	REG(d, Vrstatus) = REG(d, Vrstatus) | Sdriverok;
	coherence();
}

/*
 * Give the device a queue of (at most) n descriptors.
 *
 * One allocation in the legacy arrangement: the descriptor table, the
 * available ring straight after it, and the used ring at the next
 * Qalign boundary. xspanalloc because it must be page-aligned and
 * because it is for ever -- nothing here ever gives a queue back.
 */
static int
vqsizeok(u32int n)
{
	return n != 0 && (n & (n-1)) == 0;
}

/*
 * What the device says it wrote, cut to what it was lent to write in:
 * every driver takes this as a count of bytes in its own buffer.
 */
static u32int
vqusedlen(u32int len, u32int lent)
{
	return len > lent ? lent : len;
}

Vq*
virtioqueue(Vdev *d, int idx, int n)
{
	Vq *q;
	uchar *mem;
	ulong availoff, usedoff, size;
	u32int max;
	int i;

	if(idx < 0 || idx >= Vdevqueues)
		return nil;
	REG(d, Vrqsel) = idx;
	coherence();
	max = REG(d, Vrqnummax);
	if(max == 0){
		print("virtio: slot %d has no queue %d\n", d->slot, idx);
		return nil;
	}
	/*
	 * The ring is indexed by a 16-bit counter modulo its size, which
	 * comes out right across the counter's wrap only for a power of
	 * two.  The specification requires one; the device is not taken at
	 * its word.
	 */
	if(!vqsizeok(max)){
		print("virtio: slot %d queue %d: size %ud is not a power of two; refused\n", d->slot, idx, max);
		return nil;
	}
	if(n <= 0)
		return nil;
	if(n > Vqmax)
		n = Vqmax;
	if((u32int)n > max)
		n = max;		/* a power of two, since max is and Vqmax is */
	if(!vqsizeok(n))
		return nil;

	availoff = n * sizeof(Vqdesc);
	usedoff = ROUND(availoff + sizeof(Vqavail) + n*sizeof(u16int) + sizeof(u16int), Qalign);
	size = ROUND(usedoff + sizeof(Vqused) + n*sizeof(Vqusedelem) + sizeof(u16int), Qalign);

	q = malloc(sizeof *q);
	mem = xspanalloc(size, Qalign, 0);
	if(q == nil || mem == nil)
		panic("virtioqueue: no memory for slot %d queue %d", d->slot, idx);
	memset(mem, 0, size);

	q->dev = d;
	q->idx = idx;
	q->n = n;
	q->desc = (Vqdesc*)mem;
	q->avail = (Vqavail*)(mem + availoff);
	q->used = (Vqused*)(mem + usedoff);
	for(i = 0; i < n-1; i++)
		q->desc[i].next = q->snext[i] = i+1;
	q->desc[n-1].next = q->snext[n-1] = 0xFFFF;
	q->free = 0;
	q->nfree = n;
	q->lastused = 0;

	/* the queue's memory as it should be, THEN the registers that give it to the device */
	coherence();
	REG(d, Vrqnum) = n;
	if(d->legacy){
		REG(d, Vrqalign) = Qalign;
		REG(d, Vrqpfn) = PADDR(mem) >> PGSHIFT;
	}else{
		REG(d, Vrqdesclo) = (u32int)PADDR(q->desc);
		REG(d, Vrqdeschi) = (u32int)((u64int)PADDR(q->desc) >> 32);
		REG(d, Vrqavaillo) = (u32int)PADDR(q->avail);
		REG(d, Vrqavailhi) = (u32int)((u64int)PADDR(q->avail) >> 32);
		REG(d, Vrqusedlo) = (u32int)PADDR(q->used);
		REG(d, Vrqusedhi) = (u32int)((u64int)PADDR(q->used) >> 32);
		REG(d, Vrqready) = 1;
	}
	coherence();
	d->q[idx] = q;
	return q;
}

/*
 * Read and acknowledge the interrupt status: bit 0 is "a used ring
 * moved", bit 1 "the configuration changed". Level-sensitive, so a
 * handler that does not call this is re-entered for ever.
 */
u32int
virtiointr(Vdev *d)
{
	u32int s;

	s = REG(d, Vrintstatus);
	REG(d, Vrintack) = s;
	return s;
}

/* the device's configuration space, a byte at a time: fields are unaligned */
void
virtiocfgread(Vdev *d, int off, void *buf, int n)
{
	uchar *p;
	int i;

	p = buf;
	for(i = 0; i < n; i++)
		p[i] = *(volatile uchar*)(d->regs + Vrconfig + off + i);
}

/* and writing it: only the input device's selectors need this */
void
virtiocfgwrite(Vdev *d, int off, int v)
{
	*(volatile uchar*)(d->regs + Vrconfig + off) = v;
	coherence();
}

int
vqroom(Vq *q)
{
	return q->nfree;
}

/*
 * Queue a request of nbuf pieces. Returns the chain's head, or -1 if
 * there are not nbuf descriptors free -- the caller waits for the
 * device to finish something and tries again. The device is not told
 * until vqkick, so several requests can be queued behind one doorbell.
 *
 * Device-readable pieces must come before device-writable ones; that
 * is the specification's rule, and the caller's to follow.
 */
int
vqsubmit(Vq *q, Vbuf *b, int nbuf, void *cookie)
{
	Vqdesc *d;
	int head, i, j;
	u64int wlen;

	ilock(&q->l);
	if(nbuf <= 0 || q->nfree < nbuf){
		iunlock(&q->l);
		return -1;
	}
	head = q->free;
	j = head;
	d = nil;
	wlen = 0;
	for(i = 0; i < nbuf; i++){
		d = &q->desc[j];
		d->addr = PADDR(b[i].p);
		d->len = b[i].len;
		if(b[i].write)
			wlen += (u32int)b[i].len;
		d->flags = (b[i].write ? Vdwrite : 0) | (i < nbuf-1 ? Vdnext : 0);
		d->next = q->snext[j];	/* ours: what the device left there is not read */
		j = q->snext[j];
	}
	q->free = j;
	q->nfree -= nbuf;
	q->cookie[head] = cookie;
	q->nchain[head] = nbuf;
	q->busy[head] = 1;
	q->wlen[head] = wlen > 0xFFFFFFFFULL ? 0xFFFFFFFF : (u32int)wlen;

	/*
	 * The ring entry, a barrier, THEN the index: the index is what
	 * the device reads to learn there is something new, so everything
	 * it will go on to read must be in place first.
	 */
	q->avail->ring[q->avail->idx % q->n] = head;
	coherence();
	q->avail->idx++;
	coherence();
	iunlock(&q->l);
	return head;
}

void
vqkick(Vq *q)
{
	REG(q->dev, Vrqnotify) = q->idx;
}

/*
 * Take one finished request off the used ring: its head, how much the
 * device wrote, and the cookie it was queued with. -1 when there is
 * nothing. The chain's descriptors go back on the free list.
 */
/*
 * What a device puts in the used ring, and in the descriptors it was
 * lent, is believed only as far as the driver's own records agree: a
 * head out of range, or one not the device's (never lent, or given back
 * already), is refused and counted -- it panicked, or freed a chain
 * twice, or gave the driver back nil for its cookie -- and a chain is
 * freed by the driver's copy of its links and length, not by desc[]'s,
 * which the device can rewrite (a link out of range, or round in a
 * loop). A device that lies loses the descriptors it lied about; the
 * kernel goes on.
 */
int
vqcollect(Vq *q, u32int *lenp, void **cookiep)
{
	Vqusedelem *e;
	int head, j, k;
	u32int len;

	ilock(&q->l);
#ifdef CHAOS
	{
		ulong r;

		/* a lying device: a used entry or a shared link rewritten */
		if(q->lastused != q->used->idx && chaosdevice(&r)){
			if(r & 1)
				q->used->ring[q->lastused % q->n].id = (r >> 1) % (2*q->n);
			else
				q->desc[(r >> 1) % q->n].next = r >> 8;
		}
	}
#endif
	for(;;){
		if(q->lastused == q->used->idx){
			iunlock(&q->l);
			return -1;
		}
		/*
		 * The index, a barrier, THEN the entry it covers: the device
		 * stores them in the other order, and a load that follows a
		 * branch is not held back by it.  The entry is read once.
		 */
		coherence();
		e = &q->used->ring[q->lastused % q->n];
		q->lastused++;
		head = e->id;
		len = e->len;
		if(head >= 0 && head < q->n && q->busy[head])
			break;
		if(q->nbogus++ == 0)
			iprint("virtio: slot %d queue %d: used ring names descriptor %d, not the device's; refused\n",
				q->dev->slot, q->idx, head);
	}
	if(len > q->wlen[head] && q->nlong++ == 0)
		iprint("virtio: slot %d queue %d: device says it wrote %ud bytes in %ud lent; cut\n",
			q->dev->slot, q->idx, len, q->wlen[head]);
	if(lenp != nil)
		*lenp = vqusedlen(len, q->wlen[head]);
	if(cookiep != nil)
		*cookiep = q->cookie[head];
	q->cookie[head] = nil;
	q->busy[head] = 0;

	/* walk to the end of the chain by our links, then splice the whole of it back */
	j = head;
	for(k = 1; k < q->nchain[head]; k++)
		j = q->snext[j];
	q->nfree += q->nchain[head];
	q->snext[j] = q->free;
	q->desc[j].next = q->free;
	q->desc[j].flags = 0;
	q->free = head;
	iunlock(&q->l);
	return head;
}
