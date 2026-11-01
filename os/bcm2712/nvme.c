/*
 * NVMe on the external PCIe connector (pcie1.c). After 9front's
 * sys/src/9/port/sdnvme.c, to this kernel's shape. One I/O queue, served
 * as #S/nvme0 (../port/devsd.c), with the disk's GPT or MBR partitions
 * as nvme0p1 and so on, and #S/nvmestat for what the drive says of
 * itself. Commands are polled during boot, and after that a process
 * waits for MSI-X, through the second MIP: data 8 is GIC_SPI 255, an
 * edge, as Linux has it.
 *
 * A command that does not complete, a controller fatal status, or the
 * link going away, resets the controller and sets everything up again,
 * and the transfer is tried once more. Nothing above here asks for a
 * flush, so a process does, every Flushms; boot option nvmefua forces
 * each write to the medium instead, nearly halving kfs's speed. On the way down the
 * controller is shut down properly, or the drive counts it as a loss
 * of power.
 *
 * Boot option nvmewrite exercises writes at several places on the disk,
 * saving and restoring what is there; nvmefault loses the first command
 * after boot, to show recovery working.
 *
 * Queues are in 2MB of Normal non-cacheable memory: the bridge does not
 * snoop. Data moves through a cached buffer kept clean by hand, since a
 * copy out of non-cacheable memory is a tenth the speed. A device
 * reaches memory at PCIe 0x10_0000_0000 + pa.
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

enum
{
	Cap	= 0x00,
	Vs	= 0x08,
	Cc	= 0x14,
		Ccen	= 1<<0,
		Ccsizes	= 6<<16 | 4<<20,	/* 64-byte commands, 16-byte completions */
		Ccshn	= 1<<14,		/* normal shutdown */
	Csts	= 0x1C,
		Rdy	= 1<<0,
		Cfs	= 1<<1,
		Shstmask= 3<<2,
		Shstdone= 2<<2,
	Aqa	= 0x24,
	Asq	= 0x28,
	Acq	= 0x30,
	Doorbell= 0x1000,

	Opidentify	= 0x06,
	Opcreatecq	= 0x05,
	Opcreatesq	= 0x01,
	Opread		= 0x02,
	Oplogpage	= 0x02,		/* the admin queue's */
	Opflush		= 0x00,
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
	Iowait	= 3000,			/* ms, for one transfer */
	Linkwait= 5000,			/* ms, for a link to come back */
	Flushms	= 2000,			/* the most a power cut can lose */
	Toomany	= 4,			/* resets, before a slower link */
	Failed	= -1,			/* no answer, as opposed to a status */
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
	uchar	*id;		/* a page of non-cacheable memory, for admin commands */
	uchar	*data;
	int	maxxfer;	/* bytes, of the drive's and ours */
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
	int	msicap;
	int	canwait;	/* a process is issuing it: not the boot's stack */
	int	fua;		/* Fua, or 0 for the flush process */
	int	dirty;		/* written since the last flush */
	int	dead;		/* recovery failed */
	int	fault;		/* nvmefault: lose the next completion */
	char	name[80];
	ulong	nintr;
	ulong	nrecover;
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

/* vector 0 of the table in BAR 0, to the MIP; also after a reset */
static void
msitable(void)
{
	volatile u32int *t;
	int cap;

	cap = nvme.msicap;
	t = (u32int*)(uintptr)(PCIE1WIN + (pcie1cfgr(cap + 4) & ~7));
	t[0] = Msipcilo;
	t[1] = Msipcihi;
	t[2] = Msivec;
	t[3] = 0;
	coherence();
	pcie1cfgw(cap, (pcie1cfgr(cap) & ~(1<<30)) | 1<<31);
	pcie1cfgw(4, pcie1cfgr(4) | 1<<10);	/* no INTx */
}

/* the capability walk, then vector 0 of the table in BAR 0, to the MIP */
static void
msion(void)
{
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
	nvme.msicap = cap;
	MIP1(0x40) = 0;			/* MASKL_HOST: all to the ARM */
	MIP1(0x60) = ~0;		/* MASKL_VPU */
	MIP1(0x20) = ~0;		/* CFGL_HOST: edges */
	gicedge(IRQnvme);
	intrenable(IRQnvme, interrupt, nil, 0, "nvme");
	msitable();
	nvme.msi = 1;
}

/* the completion, once it has come; 0 if it has not */
static int
pollcq(Queue *q, int ms, u32int *stp)
{
	u32int st;
	int i;

	for(i = 0; i < ms*100; i++){
		coherence();
		st = q->cq[q->cqhead*4 + 3];
		if(((st>>16) & 1) == q->phase){
			*stp = st;
			return 1;
		}
		if(R(Csts) & Cfs)		/* ones, too, when the link has gone */
			return 0;
		microdelay(10);
	}
	return 0;
}

/* issue a command and wait for it: 0, the status, or Failed */
static int
cmd(Queue *q, int op, u32int nsid, u64int prp1, u64int prp2, u32int c10, u32int c11, u32int c12)
{
	u32int *e, st;
	int i, id, ms;

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

	ms = nvme.timeout;
	if(nvme.canwait){
		ms = Iowait;
		nvme.waiting = q;
		if(waserror()){
			/*
			 * The process is being killed, with a command
			 * under way into memory it will not wait for, and
			 * its completion would answer the next. Finish
			 * it here.
			 */
			nvme.waiting = nil;
			if(pollcq(q, ms, &st)){
				if(++q->cqhead == Nq){
					q->cqhead = 0;
					q->phase ^= 1;
				}
				*dbell(q->id, 1) = q->cqhead;
				coherence();
			}
			nexterror();
		}
		tsleep(&nvme.r, cqdone, q, ms);
		poperror();
		nvme.waiting = nil;
		ms = 1;
	}
	if(nvme.fault && q == &nvme.io){
		nvme.fault = 0;
		print("nvme: nvmefault: losing command %#ux\n", id);
		return Failed;
	}
	if(!pollcq(q, ms, &st)){
		print("nvme: command %#ux gets no answer: csts %#ux\n", op, R(Csts));
		return Failed;
	}
	if(++q->cqhead == Nq){
		q->cqhead = 0;
		q->phase ^= 1;
	}
	*dbell(q->id, 1) = q->cqhead;
	coherence();
	if((st & 0xFFFF) != id){
		print("nvme: completion for %#ux, wanted %#ux\n", st&0xFFFF, id);
		return Failed;
	}
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

/* n blocks between the medium and the data buffer, at most maxxfer */
static int
xfer(int write, uvlong lba, int n)
{
	int i, s, len, pages;

	len = n*nvme.blocksize;
	pages = (len + Pgsize-1)/Pgsize;
	for(i = 1; i < pages; i++)
		nvme.prp[i-1] = DEVADDR(nvme.data + i*Pgsize);
	if(write)
		cachedwbse(nvme.data, len);
	else
		cachedwbinvse(nvme.data, len);
	coherence();
	s = cmd(&nvme.io, write ? Opwrite : Opread, 1, DEVADDR(nvme.data),
		pages > 2 ? DEVADDR(nvme.prp) : (pages == 2 ? DEVADDR(nvme.data + Pgsize) : 0),
		(u32int)lba, lba>>32, (n-1) | (write ? nvme.fua : 0));
	if(!write)
		cachedwbinvse(nvme.data, len);
	if(s != 0)
		print("nvme: %s of %llud+%d: status %#ux\n", write ? "write" : "read", lba, n, s);
	return s;
}

#define readblocks(lba, n)	(xfer(0, (lba), (n)) == 0 ? 0 : -1)

static int enable(void);
static void devsetup(void);

/*
 * The drive stopped answering. Wait for the link, if that is what went,
 * and start again from the configuration space up. nvme.q is held.
 */
static int
recover(void)
{
	int i, wait;

	nvme.nrecover++;
	print("nvme: resetting the controller\n");
	wait = nvme.canwait;
	nvme.canwait = 0;
	if(nvme.nrecover == Toomany){
		print("nvme: too many resets: down to gen 1\n");
		pcie1slow();
		microdelay(100000);
	}
	for(i = 0; i < Linkwait && !pcie1linked(); i++)
		microdelay(1000);
	if(i == Linkwait){
		print("nvme: the link has not come back\n");
		nvme.dead = 1;
		return -1;
	}
	devsetup();
	if(enable() < 0){
		nvme.dead = 1;
		return -1;
	}
	if(nvme.msi)
		msitable();
	nvme.canwait = wait;
	print("nvme: back, %s\n", pcie1speed());
	return 0;
}

/* by hand, from #S/sdctl: let the next transfer find what is left */
void
nvmeslow(void)
{
	qlock(&nvme.q);
	pcie1slow();
	qunlock(&nvme.q);
}

/* one transfer, and if it got no answer one more after a reset */
static void
xferchecked(int write, uvlong lba, int n)
{
	int s;

	if(nvme.dead)
		error(Eio);
	s = xfer(write, lba, n);
	if(s == Failed){
		if(recover() < 0)
			error(Eio);
		s = xfer(write, lba, n);
	}
	if(s != 0)
		error(Eio);
}

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
		nvme.canwait = 0;
		qunlock(&nvme.q);
		nexterror();
	}
	nvme.canwait = nvme.msi;
	p = a;
	for(done = 0; done < n; done += m){
		lba = (off + done)/bs;
		in = (off + done)%bs;
		m = n - done;
		if(m > nvme.maxxfer - in)
			m = nvme.maxxfer - in;
		nb = (in + m + bs-1)/bs;
		if(!write || in != 0 || (m & (bs-1)) != 0)
			xferchecked(0, lba, nb);
		if(write){
			memmove(nvme.data + in, p + done, m);
			xferchecked(1, lba, nb);
			nvme.dirty = 1;
		}else
			memmove(p + done, nvme.data + in, m);
	}
	nvme.canwait = 0;
	qunlock(&nvme.q);
	poperror();
	return n;
}

static void
flushproc(void*)
{
	static Rendez r;

	while(waserror())
		;
	for(;;){
		tsleep(&r, return0, nil, Flushms);
		if(!nvme.dirty || nvme.dead)
			continue;
		qlock(&nvme.q);
		nvme.dirty = 0;
		if(cmd(&nvme.io, Opflush, 1, 0, 0, 0, 0, 0) != 0)
			nvme.dirty = 1;
		qunlock(&nvme.q);
	}
}

/* #P's init: there is a scheduler by then */
void
nvmestart(void)
{
	if(nvme.present && !nvme.fua)
		kproc("nvmeflush", flushproc, nil, 0);
}

/*
 * What the drive says of itself, for #S/nvmestat. A process, so the
 * admin queue is polled under nvme.q.
 */
long
nvmestat(char *buf, long n)
{
	uchar *l;
	char *e;
	int s;

	l = nvme.id;
	e = buf + n;
	buf = seprint(buf, e, "%s\n%llud blocks of %d, %s\nintr %lud recoveries %lud%s\n",
		nvme.name, nvme.nblocks, nvme.blocksize, pcie1speed(), nvme.nintr, nvme.nrecover,
		nvme.dead ? " dead" : "");
	qlock(&nvme.q);
	s = nvme.dead ? -1 : cmd(&nvme.admin, Oplogpage, 0xFFFFFFFF, DEVADDR(l), 0, 127<<16 | 2, 0, 0);
	if(s == 0)
		buf = seprint(buf, e, "temperature %d C, spare %d%%, used %d%%, warnings %#ux\n"
			"read %llud written %llud (of 512000 bytes)\n"
			"power cycles %llud, hours %llud, unsafe shutdowns %llud, media errors %llud\n",
			(l[1] | l[2]<<8) - 273, l[3], l[5], l[0],
			*(u64int*)(l+32), *(u64int*)(l+48), *(u64int*)(l+112), *(u64int*)(l+128),
			*(u64int*)(l+144), *(u64int*)(l+160));
	qunlock(&nvme.q);
	return strlen(e - n);
}

/*
 * The machine is going down, so spinning is fine and nobody else is
 * coming: a flush, in case anything gets written without FUA, and a
 * shutdown the drive will not count as losing power.
 */
void
nvmeshutdown(void)
{
	static int done;
	int i;

	if(!nvme.present || nvme.dead || done)
		return;
	done = 1;
	if((R(Csts) & Rdy) == 0 || R(Csts) == ~0U){
		print("nvme: down already\n");	/* the link's first drop: it holds nothing */
		return;
	}
	nvme.canwait = 0;
	if(canqlock(&nvme.q))	/* else a transfer is under way; the shutdown flushes anyway */
		cmd(&nvme.io, Opflush, 1, 0, 0, 0, 0, 0);
	R(Cc) = (R(Cc) & ~(3U<<14)) | Ccshn;
	coherence();
	for(i = 0; i < 2000 && (R(Csts) & Shstmask) != Shstdone; i++)
		microdelay(1000);
	print("nvme: shut down%s\n", i == 2000 ? ": it did not say so" : "");
}

/* the disk's partitions, GPT's or an MBR's, as nvme0p1 and on */
static void
gptscan(void)
{
	uchar *d, *e;
	char name[16];
	uvlong tab, first, last;
	int bs, i, nent, esz, n, scale;

	bs = nvme.blocksize;
	scale = bs/512;
	if(readblocks(0, 1) < 0)
		return;
	d = nvme.data;
	if(d[510] != 0x55 || d[511] != 0xAA)
		return;
	if(d[450] != 0xEE){
		for(i = 0; i < 4; i++){
			e = d + 446 + 16*i;
			first = e[8] | e[9]<<8 | e[10]<<16 | (uvlong)e[11]<<24;
			last = e[12] | e[13]<<8 | e[14]<<16 | (uvlong)e[15]<<24;
			if(e[4] == 0 || last == 0)
				continue;
			snprint(name, sizeof name, "nvme0p%d", i+1);
			sdaddnvmepart(name, first*scale, last*scale);
			print("nvme: %s mbr type %#ux from %llud, %llud MB\n", name, e[4], first, last*bs >> 20);
		}
		return;
	}
	if(readblocks(1, 1) < 0)
		return;
	if(memcmp(d, "EFI PART", 8) != 0){
		print("nvme: protective MBR and no GPT header\n");
		return;
	}
	tab = *(u64int*)(d+72);
	nent = *(u32int*)(d+80);
	esz = *(u32int*)(d+84);
	if(esz < 128 || esz > 1024)
		return;
	if(nent > 128)
		nent = 128;
	n = (nent*esz + bs-1)/bs;
	if(readblocks(tab, n) < 0)
		return;
	for(i = 0; i < nent; i++){
		e = d + i*esz;
		if(*(u64int*)e == 0 && *(u64int*)(e+8) == 0)
			continue;
		first = *(u64int*)(e+32);
		last = *(u64int*)(e+40);
		snprint(name, sizeof name, "nvme0p%d", i+1);
		sdaddnvmepart(name, first*scale, (last - first + 1)*scale);
		print("nvme: %s from %llud, %llud MB\n", name, first, (last-first+1)*bs >> 20);
	}
}

/*
 * Boot option nvmewrite: at the start, the middle and the end of the disk,
 * save 128KB, write a pattern, read it back, restore, read that back.
 */
static void
writetest(void)
{
	static uchar save[Xfer];
	uvlong at[3], lba;
	u32int *d;
	int i, k, n, bad;

	n = Xfer/nvme.blocksize;
	at[0] = 2048;
	at[1] = nvme.nblocks/2;
	at[2] = nvme.nblocks - n;
	for(k = 0; k < nelem(at); k++){
		lba = at[k];
		if(xfer(0, lba, n) != 0)
			return;
		memmove(save, nvme.data, Xfer);
		d = (u32int*)nvme.data;
		for(i = 0; i < Xfer/4; i++)
			d[i] = 0xA5C30000 ^ i*2654435761U ^ (u32int)lba;
		if(xfer(1, lba, n) != 0)
			return;
		memset(nvme.data, 0, Xfer);
		if(xfer(0, lba, n) != 0)
			return;
		bad = 0;
		for(i = 0; i < Xfer/4; i++)
			if(d[i] != (0xA5C30000 ^ i*2654435761U ^ (u32int)lba))
				bad++;
		memmove(nvme.data, save, Xfer);
		if(xfer(1, lba, n) != 0)
			return;
		memset(nvme.data, 0, Xfer);
		if(xfer(0, lba, n) != 0)
			return;
		print("nvme: write at lba %llud: %d of %d words differ, restored %s\n", lba, bad, Xfer/4,
			memcmp(nvme.data, save, Xfer) == 0 ? "ok" : "DIFFERS");
	}
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

/* the controller up from reset, with its queues empty; also after a fault */
static int
enable(void)
{
	Queue *a, *q;
	int s;

	a = &nvme.admin;
	q = &nvme.io;
	R(Cc) = 0;
	if(waitrdy(0) < 0)
		return -1;
	memset(nvme.mem, 0, 4*Pgsize);
	a->sqtail = a->cqhead = q->sqtail = q->cqhead = 0;
	a->phase = q->phase = 1;
	R(Aqa) = (Nq-1)<<16 | (Nq-1);
	R(Asq) = (u32int)DEVADDR(a->sq);
	R(Asq+4) = DEVADDR(a->sq)>>32;
	R(Acq) = (u32int)DEVADDR(a->cq);
	R(Acq+4) = DEVADDR(a->cq)>>32;
	coherence();
	R(Cc) = Ccsizes | Ccen;
	if(waitrdy(1) < 0)
		return -1;
	if((s = cmd(a, Opcreatecq, 0, DEVADDR(q->cq), 0, (Nq-1)<<16 | 1, 3, 0)) != 0){
		print("nvme: create cq: status %#ux\n", s);
		return -1;
	}
	if((s = cmd(a, Opcreatesq, 0, DEVADDR(q->sq), 0, (Nq-1)<<16 | 1, 1<<16 | 1, 0)) != 0){
		print("nvme: create sq: status %#ux\n", s);
		return -1;
	}
	return 0;
}

static int
start(void)
{
	Queue *a, *q;
	uchar *m, *id;
	char model[41], serial[21], fw[9];
	u64int cap;
	int s, lbaf, mdts;

	cap = (u64int)R(Cap+4)<<32 | R(Cap);
	nvme.dstrd = (cap>>32) & 0xF;
	nvme.timeout = ((cap>>24) & 0xFF)*500;
	if(((cap>>48) & 0xF) != 0){
		print("nvme: wants pages over 4KB\n");
		return -1;
	}

	m = xspanalloc(Dmasize, Dmasize, 0);
	if(m == nil)
		return -1;
	nvme.data = xspanalloc(Xfer, Pgsize, 0);
	if(nvme.data == nil)
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
	nvme.id = id = m + 5*Pgsize;
	a->id = 0;
	q->id = 1;

	if(enable() < 0)
		return -1;

	if((s = cmd(a, Opidentify, 0, DEVADDR(id), 0, 1, 0, 0)) != 0){
		print("nvme: identify controller: status %#ux\n", s);
		return -1;
	}
	str(serial, id+4, 20);
	str(model, id+24, 40);
	str(fw, id+64, 8);
	snprint(nvme.name, sizeof nvme.name, "%s fw %s serial %s", model, fw, serial);
	print("nvme: %s, %d namespaces\n", nvme.name, id[516]|id[517]<<8);
	mdts = id[77];
	nvme.maxxfer = Xfer;
	if(mdts != 0 && mdts < 16 && (Pgsize<<mdts) < Xfer)
		nvme.maxxfer = Pgsize<<mdts;

	if((s = cmd(a, Opidentify, 1, DEVADDR(id), 0, 0, 0, 0)) != 0){
		print("nvme: identify namespace: status %#ux\n", s);
		return -1;
	}
	nvme.nblocks = *(u64int*)id;
	lbaf = id[26] & 0xF;
	nvme.blocksize = 1<<id[128 + 4*lbaf + 2];
	print("nvme: namespace 1: %llud blocks of %d, %dKB a transfer\n", nvme.nblocks, nvme.blocksize, nvme.maxxfer/1024);
	if(nvme.blocksize < 512 || nvme.blocksize > Pgsize || id[128 + 4*lbaf] != 0 || id[129 + 4*lbaf] != 0){
		print("nvme: blocks of that shape are not supported\n");
		return -1;
	}

	msion();
	nvme.present = 1;
	return 0;
}

/* what a reset of the link takes away */
static void
devsetup(void)
{
	pcie1cfgw(0x10, 0x80000000);
	pcie1cfgw(0x14, 0);
	pcie1cfgw(4, (pcie1cfgr(4) & 0xFFFF) | 6);
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
	devsetup();
	print("nvme: %.4ux:%.4ux, version %#ux\n", id&0xFFFF, id>>16, R(Vs));
	if(start() < 0)
		return;
	readtest();
	gptscan();
	if(cmdlineword("nvmewrite"))
		writetest();
	if(cmdlineword("nvmefua"))
		nvme.fua = Fua;
	if(cmdlineword("nvmefault"))
		nvme.fault = 1;
}
