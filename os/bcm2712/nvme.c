/*
 * NVMe on the external PCIe connector (pcie1.c). After 9front's
 * sys/src/9/port/sdnvme.c, to this kernel's shape. One I/O queue, served
 * as #S/nvme0 (../port/devsd.c). Commands are polled during boot, and
 * after that a process waits for MSI-X, through the second
 * MIP: data 8 is GIC_SPI 255, an edge, as Linux has it.
 *
 * Writes reach only a scratch area, the last Scratch bytes of the disk
 * less the last Gptback, where GPT keeps its copy, and are refused
 * anywhere else while the driver is new: the drive holds real data.
 *
 * Queues, and the one page data moves through, are in 2MB of Normal
 * non-cacheable memory: the bridge does not snoop. A device reaches
 * memory at PCIe 0x10_0000_0000 + pa.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"
#include "board.h"

#define R(o)	(*(volatile u32int*)(uintptr)(PCIE1WIN + (o)))
#define DEVADDR(p)	(0x1000000000ULL + (u64int)(uintptr)(p))

#define MIP1(o)	(*(volatile u32int*)(uintptr)(0x1000131000ULL + (o)))

#define Scratch	(2ULL*1024*1024*1024)
#define Gptback	(1024*1024ULL)

enum
{
	Cap	= 0x00,
	Vs	= 0x08,
	Cc	= 0x14,
		Ccen	= 1<<0,
		Ccsizes	= 6<<16 | 4<<20,	/* 64-byte commands, 16-byte completions */
	Csts	= 0x1C,
		Rdy	= 1<<0,
		Cfs	= 1<<1,
	Aqa	= 0x24,
	Asq	= 0x28,
	Acq	= 0x30,
	Doorbell= 0x1000,

	Opidentify	= 0x06,
	Opcreatecq	= 0x05,
	Opcreatesq	= 0x01,
	Opread		= 0x02,
	Opwrite		= 0x01,

	Nq	= 64,
	Msivec	= 8,		/* the MIP's brcm,msi-offset: its first vector */
	IRQnvme	= IRQspi + 247 + Msivec,
	Msipcilo= 0xFFFFF000U,
	Msipcihi= 0xFF,
	Dmasize	= 2*1024*1024,
	Pgsize	= 4096,
	Xfer	= 128*1024,		/* one transfer: Pgsize*32 */
	Fua	= 1<<30,
};

typedef struct Queue Queue;
struct Queue
{
	u32int	*sq;
	u32int	*cq;
	int	id;
	int	sqtail;
	int	cqhead;
	int	phase;
};

static struct
{
	uchar	*mem;
	Queue	admin;
	Queue	io;
	u64int	*prp;
	uchar	*data;
	int	cmdid;
	int	dstrd;
	int	timeout;	/* ms */
	u64int	nblocks;
	int	blocksize;
	int	present;
	QLock	q;
	Rendez	r;
	Queue	*waiting;
	int	msi;
	int	canwait;	/* a process is issuing it: not the boot's stack */
	ulong	nintr;
} nvme;

static u32int*
dbell(int q, int cq)
{
	return (u32int*)(uintptr)(PCIE1WIN + Doorbell + (2*q + cq)*(4<<nvme.dstrd));
}

static int
cqdone(void *a)
{
	Queue *q;

	q = a;
	return ((q->cq[q->cqhead*4 + 3]>>16) & 1) == q->phase;
}

static void
interrupt(Ureg*, void*)
{
	nvme.nintr++;
	wakeup(&nvme.r);
}

/* the capability walk, then vector 0 of the table in BAR 0, to the MIP */
static void
msion(void)
{
	volatile u32int *t;
	u32int v;
	int cap;

	for(cap = pcie1cfgr(0x34) & 0xFC; cap != 0; cap = (v>>8) & 0xFC){
		v = pcie1cfgr(cap);
		if((v & 0xFF) == 0x11)
			break;
	}
	if(cap == 0){
		print("nvme: no MSI-X: polling\n");
		return;
	}
	v = pcie1cfgr(cap + 4);
	if((v & 7) != 0){
		print("nvme: MSI-X table in BAR %d: polling\n", v & 7);
		return;
	}
	MIP1(0x40) = 0;			/* MASKL_HOST: all to the ARM */
	MIP1(0x60) = ~0;		/* MASKL_VPU */
	MIP1(0x20) = ~0;		/* CFGL_HOST: edges */
	gicedge(IRQnvme);
	intrenable(IRQnvme, interrupt, nil, 0, "nvme");
	t = (u32int*)(uintptr)(PCIE1WIN + (v & ~7));
	t[0] = Msipcilo;
	t[1] = Msipcihi;
	t[2] = Msivec;
	t[3] = 0;
	coherence();
	pcie1cfgw(cap, (pcie1cfgr(cap) & ~(1<<30)) | 1<<31);
	pcie1cfgw(4, pcie1cfgr(4) | 1<<10);	/* no INTx */
	nvme.msi = 1;
}

/* issue a command and wait for it; 0 or the status */
static int
cmd(Queue *q, int op, u32int nsid, u64int prp1, u64int prp2, u32int c10, u32int c11, u32int c12)
{
	u32int *e, *c, st;
	int i, id;

	id = ++nvme.cmdid & 0xFFFF;
	e = &q->sq[q->sqtail*16];
	for(i = 0; i < 16; i++)
		e[i] = 0;
	e[0] = op | id<<16;
	e[1] = nsid;
	e[6] = (u32int)prp1;
	e[7] = prp1>>32;
	e[8] = (u32int)prp2;
	e[9] = prp2>>32;
	e[10] = c10;
	e[11] = c11;
	e[12] = c12;
	coherence();
	q->sqtail = (q->sqtail + 1) % Nq;
	*dbell(q->id, 0) = q->sqtail;
	coherence();

	c = &q->cq[q->cqhead*4];
	if(nvme.canwait){
		nvme.waiting = q;
		tsleep(&nvme.r, cqdone, q, nvme.timeout);
		nvme.waiting = nil;
	}
	for(i = 0; i < nvme.timeout*100; i++){
		coherence();
		st = c[3];
		if(((st>>16) & 1) == q->phase)
			break;
		if(nvme.canwait){
			i = nvme.timeout*100;	/* tsleep gave it the whole timeout */
			break;
		}
		microdelay(10);
	}
	if(i >= nvme.timeout*100){
		print("nvme: command %#ux timed out: csts %#ux\n", op, R(Csts));
		return -1;
	}
	if(++q->cqhead == Nq){
		q->cqhead = 0;
		q->phase ^= 1;
	}
	*dbell(q->id, 1) = q->cqhead;
	coherence();
	if((st & 0xFFFF) != id)
		print("nvme: completion for %#ux, wanted %#ux\n", st&0xFFFF, id);
	return (st>>17) & 0x7FFF;
}

static void
str(char *to, uchar *from, int n)
{
	memmove(to, from, n);
	to[n] = 0;
	while(n > 0 && (to[n-1] == ' ' || to[n-1] == 0))
		to[--n] = 0;
}

static int
waitrdy(int want)
{
	int i;

	for(i = 0; i < nvme.timeout; i++){
		if((R(Csts) & Rdy) == want)
			return 0;
		if(R(Csts) & Cfs)
			break;
		microdelay(1000);
	}
	print("nvme: not %s: csts %#ux\n", want ? "ready" : "stopped", R(Csts));
	return -1;
}

/* n blocks between the medium and the data page, at most Xfer */
static int
xfer(int write, uvlong lba, int n)
{
	int i, s, pages;

	if(write)
	if(lba*nvme.blocksize < nvmelength() - Scratch ||
	   (lba+n)*nvme.blocksize > nvmelength() - Gptback){
		print("nvme: write of %llud+%d refused: outside the scratch area\n", lba, n);
		return -1;
	}
	pages = (n*nvme.blocksize + Pgsize-1)/Pgsize;
	for(i = 1; i < pages; i++)
		nvme.prp[i-1] = DEVADDR(nvme.data + i*Pgsize);
	coherence();
	s = cmd(&nvme.io, write ? Opwrite : Opread, 1, DEVADDR(nvme.data),
		pages > 2 ? DEVADDR(nvme.prp) : (pages == 2 ? DEVADDR(nvme.data + Pgsize) : 0),
		(u32int)lba, lba>>32, (n-1) | (write ? Fua : 0));
	if(s != 0)
		print("nvme: %s of %llud+%d: status %#ux\n", write ? "write" : "read", lba, n, s);
	return s == 0 ? 0 : -1;
}

#define readblocks(lba, n)	xfer(0, (lba), (n))

int
nvmepresent(void)
{
	return nvme.present;
}

vlong
nvmelength(void)
{
	return nvme.nblocks*nvme.blocksize;
}

/* bytes to or from the disk, at any offset; a short block is read first */
long
nvmerw(int write, void *a, long n, vlong off)
{
	uchar *p;
	vlong len;
	uvlong lba;
	long done, m;
	int bs, in, nb;

	bs = nvme.blocksize;
	len = nvmelength();
	if(off >= len || n <= 0)
		return 0;
	if(off + n > len)
		n = len - off;
	qlock(&nvme.q);
	if(waserror()){
		qunlock(&nvme.q);
		nexterror();
	}
	nvme.canwait = nvme.msi;
	p = a;
	for(done = 0; done < n; done += m){
		lba = (off + done)/bs;
		in = (off + done)%bs;
		m = n - done;
		if(m > Xfer - in)
			m = Xfer - in;
		nb = (in + m + bs-1)/bs;
		if(!write || in != 0 || (m & (bs-1)) != 0)
			if(xfer(0, lba, nb) < 0)
				error(Eio);
		if(write){
			memmove(nvme.data + in, p + done, m);
			coherence();
			if(xfer(1, lba, nb) < 0)
				error(Eio);
		}else
			memmove(p + done, nvme.data + in, m);
	}
	qunlock(&nvme.q);
	poperror();
	return n;
}

/*
 * Boot option nvmewrite: in the scratch area, save 128KB, write a
 * pattern, read it back, restore, read that back. Then, to prove the
 * fence, a write just below the area, which must be refused.
 */
static void
writetest(void)
{
	static uchar save[Xfer];
	uvlong lba, below;
	u32int *d;
	int i, n, bad;

	n = Xfer/nvme.blocksize;
	lba = (nvmelength() - Gptback)/nvme.blocksize - 2*n;
	below = (nvmelength() - Scratch)/nvme.blocksize - n;
	if(xfer(0, lba, n) < 0)
		return;
	memmove(save, nvme.data, Xfer);
	d = (u32int*)nvme.data;
	for(i = 0; i < Xfer/4; i++)
		d[i] = 0xA5C30000 ^ i*2654435761U;
	if(xfer(1, lba, n) < 0)
		return;
	memset(nvme.data, 0, Xfer);
	if(xfer(0, lba, n) < 0)
		return;
	bad = 0;
	for(i = 0; i < Xfer/4; i++)
		if(d[i] != (0xA5C30000 ^ i*2654435761U))
			bad++;
	print("nvme: write test at lba %llud: %d of %d words differ\n", lba, bad, Xfer/4);
	memmove(nvme.data, save, Xfer);
	coherence();
	if(xfer(1, lba, n) < 0)
		return;
	memset(nvme.data, 0, Xfer);
	if(xfer(0, lba, n) < 0)
		return;
	print("nvme: restored: %s\n", memcmp(nvme.data, save, Xfer) == 0 ? "matches" : "DIFFERS");
	if(xfer(1, below, n) == 0)
		print("nvme: FENCE FAILED: a write below the scratch area went through\n");
	else
		print("nvme: fence holds\n");
}

/*
 * Whether the medium reads as it should, at boot: block 0, and how fast.
 */
static void
readtest(void)
{
	uvlong t0, us;
	int i, n, b;

	if(readblocks(0, 1) < 0)
		return;
	print("nvme: lba 0: signature %.2ux%.2ux, partition type %#.2ux\n",
		nvme.data[510], nvme.data[511], nvme.data[450]);
	n = Xfer/nvme.blocksize;
	t0 = fastticks2ns(fastticks(nil));
	for(i = 0; i < 2000; i++)
		if(readblocks(i*n, n) < 0)
			return;
	us = (fastticks2ns(fastticks(nil)) - t0)/1000;
	b = 2000*(Xfer/1024);
	print("nvme: read %dMB in %llud ms: %llud MB/s\n", b/1024, us/1000, (uvlong)b*1000/(us/1000 + 1)/1024);
}

static int
start(void)
{
	Queue *a, *q;
	uchar *m, *id;
	char model[41], serial[21], fw[9];
	u64int cap;
	int s, lbaf;

	cap = (u64int)R(Cap+4)<<32 | R(Cap);
	nvme.dstrd = (cap>>32) & 0xF;
	nvme.timeout = ((cap>>24) & 0xFF)*500;

	m = xspanalloc(Dmasize, Dmasize, 0);
	if(m == nil)
		return -1;
	cachedwbinvse(m, Dmasize);
	mmunormalnc((uintptr)m, Dmasize);
	memset(m, 0, Dmasize);
	nvme.mem = m;
	a = &nvme.admin;
	q = &nvme.io;
	a->sq = (u32int*)m;
	a->cq = (u32int*)(m + Pgsize);
	q->sq = (u32int*)(m + 2*Pgsize);
	q->cq = (u32int*)(m + 3*Pgsize);
	nvme.prp = (u64int*)(m + 4*Pgsize);
	nvme.data = m + 16*Pgsize;
	id = nvme.data;
	a->id = 0;
	a->phase = 1;
	q->id = 1;
	q->phase = 1;

	R(Cc) = 0;
	if(waitrdy(0) < 0)
		return -1;
	pcie1cfgw(4, (pcie1cfgr(4) & 0xFFFF) | 6);	/* it may master now */
	R(Aqa) = (Nq-1)<<16 | (Nq-1);
	R(Asq) = (u32int)DEVADDR(a->sq);
	R(Asq+4) = DEVADDR(a->sq)>>32;
	R(Acq) = (u32int)DEVADDR(a->cq);
	R(Acq+4) = DEVADDR(a->cq)>>32;
	coherence();
	R(Cc) = Ccsizes | Ccen;
	if(waitrdy(1) < 0)
		return -1;

	if((s = cmd(a, Opidentify, 0, DEVADDR(id), 0, 1, 0, 0)) != 0){
		print("nvme: identify controller: status %#ux\n", s);
		return -1;
	}
	str(serial, id+4, 20);
	str(model, id+24, 40);
	str(fw, id+64, 8);
	print("nvme: %s fw %s serial %s, %d namespaces\n", model, fw, serial, id[516]|id[517]<<8);

	if((s = cmd(a, Opidentify, 1, DEVADDR(id), 0, 0, 0, 0)) != 0){
		print("nvme: identify namespace: status %#ux\n", s);
		return -1;
	}
	nvme.nblocks = *(u64int*)id;
	lbaf = id[26] & 0xF;
	nvme.blocksize = 1<<id[128 + 4*lbaf + 2];
	print("nvme: namespace 1: %llud blocks of %d\n", nvme.nblocks, nvme.blocksize);

	/* an I/O queue pair, polled */
	if((s = cmd(a, Opcreatecq, 0, DEVADDR(q->cq), 0, (Nq-1)<<16 | 1, 3, 0)) != 0){
		print("nvme: create cq: status %#ux\n", s);
		return -1;
	}
	if((s = cmd(a, Opcreatesq, 0, DEVADDR(q->sq), 0, (Nq-1)<<16 | 1, 1<<16 | 1, 0)) != 0){
		print("nvme: create sq: status %#ux\n", s);
		return -1;
	}
	msion();
	nvme.present = 1;
	return 0;
}

void
nvmelink(void)
{
	u32int id, cls;

	if(pcie1up() < 0)
		return;
	id = pcie1cfgr(0);
	cls = pcie1cfgr(8);
	if(id == 0xFFFFFFFF || cls>>8 != 0x010802){
		print("nvme: %#.8ux class %#.8ux is not an NVMe controller\n", id, cls);
		return;
	}
	pcie1cfgw(0x10, 0x80000000);
	pcie1cfgw(0x14, 0);
	pcie1cfgw(4, (pcie1cfgr(4) & 0xFFFF) | 2);
	print("nvme: %.4ux:%.4ux, version %#ux\n", id&0xFFFF, id>>16, R(Vs));
	if(start() < 0)
		return;
	readtest();
	if(cmdlineword("nvmewrite"))
		writetest();
}
