/*
 * GENET: the BCM2711's gigabit Ethernet MAC, and the BCM54213PE PHY
 * behind it on MDIO. A Raspberry Pi 4's Ethernet socket.
 *
 * Derived from 9front's sys/src/9/bcm64/ethergenet.c (MIT: Copyright ©
 * 2021 Plan 9 Foundation, Copyright © 9front authors). The register
 * definitions, the ring arithmetic and the order things are done in are
 * that driver's, kept as close as this tree allows, because
 *
 * NOT ONE LINE OF THIS FILE HAS EVER EXECUTED AGAINST A GENET. QEMU's
 * raspi4b has no model of it and there is no Pi 4 on the bench. It
 * compiles, it links, and under QEMU it finds nothing at its address
 * and says so. A driver written blind is safest as the smallest
 * possible distance from one that works, so what follows lists every
 * place this differs from the original, and why; anything not listed
 * is 9front's.
 *
 *   Registers are volatile. Plan 9's compilers do not reorder or elide
 *   stores through a pointer; clang does, and a descriptor written and
 *   never read back is exactly what it removes.
 *
 *   No anonymous struct members: the Rendez in a Ring, the Lock and
 *   QLock in the Ctlr and the Mii all have names.
 *
 *   No block pools. 9front receives into a Bpool of aligned blocks;
 *   this tree has allocb. newrxblock() asks for a block two cache lines
 *   larger than the buffer and starts the buffer on a line boundary, so
 *   that no line the device writes is shared with anything the CPU
 *   might have dirty -- which, when it is written back, silently undoes
 *   part of a received frame. A receive buffer is cleaned and
 *   invalidated before the MAC is given it and again when it comes
 *   back; a transmit buffer is only cleaned. (cachedwbinvse and
 *   cachedwbse, ../arm64/arch.S; 9front's dmaflush.)
 *
 *   Every wait is bounded. The original spins for ever on the DMA
 *   engines' status and on MDIO's busy bit. Here those give up and say
 *   so, because the first time this runs it will be on a board nobody
 *   has debugged, from kmain, where a hang is a black screen.
 *
 *   It asks before it touches. ethergenetlink() reads the block's
 *   revision register through probe32 (../arm64/trap.c): an abort, or a
 *   major revision that is not GENETv5's, leaves instance 0 to the USB
 *   Ethernet path and prints why.
 *
 *   It fills in ../port/etherif.h's Ether, not 9front's: the Netif is
 *   a named member, a received frame goes up through etheriqb(), and
 *   devether calls transmit() after queueing a frame -- for which there
 *   is nothing to do here, since genet-send sleeps in qbread on the
 *   same queue.
 *
 *   ifstats says what the driver saw, for the day it is first tried.
 *
 * ADDRESSES. The MAC masters the full physical address space (it is on
 * the SoC's "scb" bus, whose dma-ranges are the identity), so buffers
 * are not taken from ../bcm/dmamem.c's arena and addresses do not go
 * through busaddr(): a descriptor holds a 40-bit physical address. The
 * interrupt numbers are Linux's GIC_SPI 157 and 158, and 9front's
 * IRQether = 160+29 agrees.
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
#include "../port/ethermii.h"
#include "board.h"

enum
{
	Rbsz		= 2048,		/* a multiple of the cache line: see newrxblock */
	Cacheline	= 64,
	Maxtu		= 1536,

	DmaOWN		= 0x8000,
	DmaSOP		= 0x2000,
	DmaEOP		= 0x4000,
	DmaRxLg		= 0x10,
	DmaRxNo		= 0x08,
	DmaRxErr	= 0x04,
	DmaRxCrc	= 0x02,
	DmaRxOv		= 0x01,
	DmaRxErrors	= DmaRxLg|DmaRxNo|DmaRxErr|DmaRxCrc|DmaRxOv,

	DmaTxQtag	= 0x1F80,
	DmaTxUnderrun	= 0x0200,
	DmaTxAppendCrc	= 0x0040,
	DmaTxOwCrc	= 0x0020,
	DmaTxDoCsum	= 0x0010,

	/* Ctlr->regs */
	SysRevision	= 0x00/4,
	SysPortCtrl	= 0x04/4,
		PortModeIntEphy	= 0,
		PortModeIntGphy = 1,
		PortModeExtEphy = 2,
		PortModeExtGphy = 3,
		PortModeExtRvmii50 = 4,
		PortModeExtRvmii25 = 16 | 4,
		LedActSourceMac = 1 << 9,

	SysRbufFlushCtrl	= 0x08/4,
	SysTbufFlushCtrl	= 0x0C/4,

	ExtRgmiiOobCtrl	= 0x8C/4,
		RgmiiLink	= 1 << 4,
		OobDisable	= 1 << 5,
		RgmiiModeEn	= 1 << 6,
		IdModeDis	= 1 << 16,

	Intrl0		= 0x200/4,
		IrqScb		= 1 << 0,
		IrqEphy		= 1 << 1,
		IrqPhyDetR	= 1 << 2,
		IrqPhyDetF	= 1 << 3,
		IrqLinkUp	= 1 << 4,
		IrqLinkDown	= 1 << 5,
		IrqUmac		= 1 << 6,
		IrqUmacTsv	= 1 << 7,
		IrqTbufUnderrun	= 1 << 8,
		IrqRbufOverflow	= 1 << 9,
		IrqHfbSm	= 1 << 10,
		IrqHfbMm	= 1 << 11,
		IrqMpdR		= 1 << 12,
		IrqRxDmaDone	= 1 << 13,
		IrqRxDmaPDone	= 1 << 14,
		IrqRxDmaBDone	= 1 << 15,
		IrqTxDmaDone	= 1 << 16,
		IrqTxDmaPDone	= 1 << 17,
		IrqTxDmaBDone	= 1 << 18,
		IrqMdioDone	= 1 << 23,
		IrqMdioError	= 1 << 24,
	Intrl1		= 0x240/4,
		/* Intrl0/1 + ... */
		IntrSts		= 0x00/4,
		IntrSet		= 0x04/4,
		IntrClr		= 0x08/4,
		IntrMaskSts	= 0x0C/4,
		IntrMaskSet	= 0x10/4,
		IntrMaskClr	= 0x14/4,

	RbufCtrl	= 0x300/4,
		Rbuf64En	= 1 << 0,
		RbufAlign2B	= 1 << 1,
		RbufBadDis	= 1 << 2,

	RbufChkCtrl	= 0x314/4,
		RbufChkRxChkEn	= 1 << 0,
		RbufChkSkipFcs	= 1 << 4,

	RbufOvflCnt	= 0x394/4,
	RbufErrCnt	= 0x398/4,

	RbufEnergyCtrl	= 0x39c/4,
		RbufEeeEn	= 1 << 0,
		RbufPmEn	= 1 << 1,

	RbufTbufSizeCtrl= 0x3b4/4,

	TbufCtrl	= 0x600/4,
	TbufBpMc	= 0x60C/4,
	TbufEnergyCtrl	= 0x614/4,

	UmacCmd		= 0x808/4,
		CmdTxEn		= 1 << 0,
		CmdRxEn		= 1 << 1,
		CmdSpeed10	= 0 << 2,
		CmdSpeed100	= 1 << 2,
		CmdSpeed1000	= 2 << 2,
		CmdSpeedMask	= 3 << 2,
		CmdProm		= 1 << 4,
		CmdPadEn	= 1 << 5,
		CmdCrcFwd	= 1 << 6,
		CmdPauseFwd	= 1 << 7,
		CmdRxPauseIgn	= 1 << 8,
		CmdTxAddrIn	= 1 << 9,
		CmdHdEn		= 1 << 10,
		CmdSwReset	= 1 << 13,
		CmdLclLoopEn	= 1 << 15,
		CmdAutoConfig	= 1 << 22,
		CmdCntlFrmEn	= 1 << 23,
		CmdNoLenChk	= 1 << 24,
		CmdRmtLoopEn	= 1 << 25,
		CmdPrblEn	= 1 << 27,
		CmdTxPauseIgn	= 1 << 28,
		CmdTxRxEn	= 1 << 29,
		CmdRuntFilterDis= 1 << 30,

	UmacMac0	= 0x80C/4,
	UmacMac1	= 0x810/4,
	UmacMaxFrameLen	= 0x814/4,

	UmacEeeCtrl	= 0x864/4,	
		UmacEeeEn	= 1<<3,

	UmacEeeLpiTimer	= 0x868/4,
	UmacEeeWakeTimer= 0x86C/4,
	UmacEeeRefCount	= 0x870/4,
		EeeRefCountMask = 0xFFFF,

	UmacTxFlush	= 0xb34/4,

	UmacMibCtrl	= 0xd80/4,
		MibResetRx	= 1 << 0,
		MibResetRunt	= 1 << 1,
		MibResetTx	= 1 << 2,

	MdioCmd		= 0xe14/4,
		MdioStartBusy	= 1 << 29,
		MdioReadFail	= 1 << 28,
		MdioRead	= 2 << 26,
		MdioWrite	= 1 << 26,
		MdioPhyShift	= 21,
		MdioPhyMask	= 0x1F,
		MdioAddrShift	= 16,
		MdioAddrMask	= 0x1F,

	UmacMpdCtrl	= 0xe20/4,
		MpdEn	= 1 << 0,
		MpdPwEn	= 1 << 27,

	UmacMdfCtrl	= 0xe50/4,
	UmacMdfAddr0	= 0xe54/4,

	RdmaOffset	= 0x2000/4,
	TdmaOffset	= 0x4000/4,
	HfbOffset	= 0x8000/4,

	HfbCtlr		= 0xFC00/4,
	HfbFltEnable	= 0xFC04/4,
	HfbFltLen	= 0xFC1C/4,

	/* common Ring->regs */
	RdmaWP		= 0x00/4,
	TdmaRP		= 0x00/4,
	RxWP		= 0x08/4,
	TxRP		= 0x08/4,
	TxWP		= 0x0C/4,
	RxRP		= 0x0C/4,
	DmaRingBufSize	= 0x10/4,
	DmaStart	= 0x14/4,
	DmaEnd		= 0x1C/4,
	DmaDoneThresh	= 0x24/4,
	TdmaFlowPeriod	= 0x28/4,
	RdmaXonXoffThresh=0x28/4,
	TdmaWP		= 0x2C/4,
	RdmaRP		= 0x2C/4,

	/*
	 * reg offsets only for RING16
	 * ctlr->rx->regs / ctlr->tx->regs
	 */
	RingCfg		= 0x40/4,
		RxRingCfgMask	= 0x10000,
		TxRingCfgMask	= 0x1000F,

	DmaCtrl		= 0x44/4,
		DmaCtrlEn	= 1 << 0,
	DmaStatus	= 0x48/4,
		DmaStatusDis	= 1 << 0,
	DmaScbBurstSize	= 0x4C/4,

	TdmaArbCtrl	= 0x6C/4,
	TdmaPriority0	= 0x70/4,
	TdmaPriority1	= 0x74/4,
	TdmaPriority2	= 0x78/4,

	RdmaTimeout0	= 0x6C/4,
	RdmaIndex2Ring0	= 0xB0/4,
};

typedef struct Desc Desc;
typedef struct Ring Ring;
typedef struct Ctlr Ctlr;

struct Desc
{
	volatile u32int	*d;	/* hw descriptor: three words in the block's own memory */
	Block	*b;
};

struct Ring
{
	Rendez	r;
	volatile u32int	*regs;
	volatile u32int	*intregs;
	u32int	intmask;

	Desc	*d;

	u32int	m;
	u32int	cp;
	u32int	rp;
	u32int	wp;

	int	num;
};

struct Ctlr
{
	Lock	l;
	volatile u32int	*regs;

	Desc	rd[256];
	Desc	td[256];

	Ring	rx[1+0];
	Ring	tx[1+0];

	Rendez	avail[1];
	Rendez	link[1];
	Mii	mii[1];
	Rendez	miir[1];

	QLock	alock;
	char	attached;
	char	name[16];

	/* what ifstats reports */
	ulong	nintr0;
	ulong	nintr1;
	ulong	nrx;
	ulong	nrxbad;		/* a descriptor that was not one whole good frame */
	ulong	ntx;
	ulong	nnobuf;		/* receive blocks that had to be waited for */
	ulong	nmdiotimeout;
	u32int	rev;
};

static Block *scratch;

#define	REG(x)	(x)

static void
interrupt0(Ureg *ur, void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	u32int sts;

	USED(ur);
	ctlr->nintr0++;
	sts = REG(ctlr->regs[Intrl0 + IntrSts]) & ~REG(ctlr->regs[Intrl0 + IntrMaskSts]);
	REG(ctlr->regs[Intrl0 + IntrClr]) = sts;
	REG(ctlr->regs[Intrl0 + IntrMaskSet]) = sts;

	if(sts & ctlr->rx->intmask)
		wakeup(&ctlr->rx->r);
	if(sts & ctlr->tx->intmask)
		wakeup(&ctlr->tx->r);

	if(sts & (IrqMdioDone|IrqMdioError))
		wakeup(ctlr->miir);
	if(sts & (IrqLinkUp|IrqLinkDown))
		wakeup(ctlr->link);
}

static void
interrupt1(Ureg *ur, void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	u32int sts;
	int i;

	USED(ur);
	ctlr->nintr1++;
	sts = REG(ctlr->regs[Intrl1 + IntrSts]) & ~REG(ctlr->regs[Intrl1 + IntrMaskSts]);
	REG(ctlr->regs[Intrl1 + IntrClr]) = sts;
	REG(ctlr->regs[Intrl1 + IntrMaskSet]) = sts;

	for(i = 1; i < nelem(ctlr->rx); i++)
		if(sts & ctlr->rx[i].intmask)
			wakeup(&ctlr->rx[i].r);

	for(i = 1; i < nelem(ctlr->tx); i++)
		if(sts & ctlr->tx[i].intmask)
			wakeup(&ctlr->tx[i].r);
}

static void
setdma(Desc *d, void *v)
{
	u64int pa = PADDR(v);
	REG(d->d[1]) = pa;
	REG(d->d[2]) = pa >> 32;
}

/*
 * A receive buffer nothing else shares a cache line with: Rbsz bytes
 * starting on a line boundary, inside a block two lines larger. allocb
 * puts the data at the END of its allocation, so rounding rp up stays
 * inside it.
 */
static Block*
newrxblock(void)
{
	Block *b;

	b = iallocb(Rbsz + 2*Cacheline);
	if(b == nil)
		return nil;
	b->rp = (uchar*)ROUND((uintptr)b->rp, Cacheline);
	b->wp = b->rp;
	if(b->rp + Rbsz > b->lim)
		panic("genet: receive block: rp %#p lim %#p", b->rp, b->lim);
	return b;
}

static void
replenish(Ctlr *c, Desc *d)
{
	while((d->b = newrxblock()) == nil){
		c->nnobuf++;
		resrcwait("out of genet rx buffers");
	}
	cachedwbinvse(d->b->rp, Rbsz);
	setdma(d, d->b->rp);
}

static int
rxdone(void *arg)
{
	Ring *r = arg;

	r->wp = REG(r->regs[RxWP]) & 0xFFFF;
	if(r->rp != r->wp)
		return 1;
	REG(r->intregs[IntrMaskClr]) = r->intmask;
	return 0;
}

static void
recvproc(void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	Desc *d;
	Block *b;
	u32int s;

	while(waserror())
		;

	for(;;){
		if(ctlr->rx->rp == ctlr->rx->wp){
			sleep(&ctlr->rx->r, rxdone, ctlr->rx);
			continue;
		}
		d = &ctlr->rx->d[ctlr->rx->rp & ctlr->rx->m];
		b = d->b;
		cachedwbinvse(b->rp, Rbsz);
		s = REG(d->d[0]);
		replenish(ctlr, d);
		coherence();
		ctlr->rx->rp = (ctlr->rx->rp + 1) & 0xFFFF;
		REG(ctlr->rx->regs[RxRP]) = ctlr->rx->rp;
		if((s & (DmaSOP|DmaEOP|DmaRxErrors)) != (DmaSOP|DmaEOP)){
			ctlr->nrxbad++;
			freeb(b);
			continue;
		}
		b->wp += (s & 0x0FFF0000) >> 16;
		ctlr->nrx++;
		edev->nif.inpackets++;
		etheriqb(edev, b);
	}
}

static int
txavail(void *arg)
{
	Ring *r = arg;

	return ((r->wp+1) & r->m) != (r->cp & r->m);
}

static void
sendproc(void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	Desc *d;
	Block *b;

	while(waserror())
		;

	for(;;){
		if(!txavail(ctlr->tx)){
			sleep(ctlr->avail, txavail, ctlr->tx);
			continue;
		}
		if((b = qbread(edev->oq, 100000)) == nil)
			break;
		d = &ctlr->tx->d[ctlr->tx->wp & ctlr->tx->m];
		assert(d->b == nil);
		d->b = b;
		cachedwbse(b->rp, BLEN(b));
		setdma(d, b->rp);
		REG(d->d[0]) = BLEN(b)<<16 | DmaTxQtag | DmaSOP | DmaEOP | DmaTxAppendCrc;
		coherence();
		ctlr->tx->wp = (ctlr->tx->wp+1) & 0xFFFF;
		REG(ctlr->tx->regs[TxWP]) = ctlr->tx->wp;
		ctlr->ntx++;
		edev->nif.outpackets++;
	}
	print("genet: the output queue was closed; nothing more will be sent\n");
	pexit("genet-send", 0);
}

/*
 * devether queues a frame and then calls this. genet-send is asleep in
 * qbread on that queue and the qbwrite woke it, so there is nothing
 * left to do -- but a driver with no transmit is, to devether, not a
 * driver (../port/etherif.h).
 */
static void
transmit(Ether *edev)
{
	USED(edev);
}

static int
txdone(void *arg)
{
	Ring *r = arg;

	if(r->cp != r->wp){
		r->rp = REG(r->regs[TxRP]) & 0xFFFF;
		if(r->cp != r->rp)
			return 1;
	}
	REG(r->intregs[IntrMaskClr]) = r->intmask;
	return 0;
}

static void
freeproc(void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	Desc *d;

	while(waserror())
		;

	for(;;){
		if(ctlr->tx->cp == ctlr->tx->rp){
			wakeup(ctlr->avail);
			sleep(&ctlr->tx->r, txdone, ctlr->tx);
			continue;
		}
		d = &ctlr->tx->d[ctlr->tx->cp & ctlr->tx->m];
		assert(d->b != nil);
		freeb(d->b);
		d->b = nil;
		coherence();
		ctlr->tx->cp = (ctlr->tx->cp+1) & 0xFFFF;
	}
}

static void
initring(Ring *ring, Desc *desc, int start, int size)
{
	ring->d = &desc[start];
	ring->m = size - 1;
	ring->cp = ring->rp = ring->wp = 0;
	REG(ring->regs[RxWP]) = 0;
	REG(ring->regs[RxRP]) = 0;
	REG(ring->regs[DmaStart]) = start*3;
	REG(ring->regs[DmaEnd]) = (start+size)*3 - 1;
	REG(ring->regs[RdmaWP]) = start*3;
	REG(ring->regs[RdmaRP]) = start*3;
	REG(ring->regs[DmaRingBufSize]) = (size << 16) | Rbsz;
	REG(ring->regs[DmaDoneThresh]) = 1;
}

static void
introff(Ctlr *ctlr)
{
	REG(ctlr->regs[Intrl0 + IntrMaskSet]) = -1;
	REG(ctlr->regs[Intrl0 + IntrClr]) = -1;
	REG(ctlr->regs[Intrl1 + IntrMaskSet]) = -1;
	REG(ctlr->regs[Intrl1 + IntrClr]) = -1;
}

/*
 * Wait for a DMA engine to say it is (on=0) stopped or (on=1) running.
 * The original waits for ever; 100ms is ten thousand times what the
 * engine needs, and this is called from kmain.
 */
static int
dmawait(Ring *ring, char *which, int on)
{
	int i;

	for(i = 0; i < 10000; i++){
		if(((REG(ring->regs[DmaStatus]) & DmaStatusDis) == 0) == on)
			return 0;
		microdelay(10);
	}
	print("genet: %s DMA would not %s (status %#ux)\n", which, on ? "start" : "stop",
		REG(ring->regs[DmaStatus]));
	return -1;
}

static int
dmaoff(Ctlr *ctlr)
{
	int r;

	REG(ctlr->rx->regs[DmaCtrl]) &= ~(RxRingCfgMask<<1 | DmaCtrlEn);
	REG(ctlr->tx->regs[DmaCtrl]) &= ~(TxRingCfgMask<<1 | DmaCtrlEn);

	REG(ctlr->regs[UmacTxFlush]) = 1;
	microdelay(10);
	REG(ctlr->regs[UmacTxFlush]) = 0;

	r = dmawait(ctlr->rx, "receive", 0);
	r |= dmawait(ctlr->tx, "transmit", 0);
	return r;
}

static int
dmaon(Ctlr *ctlr)
{
	int r;

	REG(ctlr->rx->regs[DmaCtrl]) |= DmaCtrlEn;
	REG(ctlr->tx->regs[DmaCtrl]) |= DmaCtrlEn;

	r = dmawait(ctlr->rx, "receive", 1);
	r |= dmawait(ctlr->tx, "transmit", 1);
	return r;
}

static void
allocbufs(Ctlr *ctlr)
{
	int i;

	if(scratch == nil){
		scratch = newrxblock();
		if(scratch == nil)
			error("out of rx buffers");
		memset(scratch->rp, 0xFF, Rbsz);
		cachedwbse(scratch->rp, Rbsz);
	}

	for(i = 0; i < nelem(ctlr->rd); i++){
		ctlr->rd[i].d = &ctlr->regs[RdmaOffset + i*3];
		replenish(ctlr, &ctlr->rd[i]);
	}

	for(i = 0; i < nelem(ctlr->td); i++){
		ctlr->td[i].d = &ctlr->regs[TdmaOffset + i*3];
		setdma(&ctlr->td[i], scratch->rp);
		REG(ctlr->td[i].d[0]) = DmaTxUnderrun;
	}
}

static void
freebufs(Ctlr *ctlr)
{
	int i;

	for(i = 0; i < nelem(ctlr->rd); i++){
		if(ctlr->rd[i].b != nil){
			freeb(ctlr->rd[i].b);
			ctlr->rd[i].b = nil;
		}
	}
	for(i = 0; i < nelem(ctlr->td); i++){
		if(ctlr->td[i].b != nil){
			freeb(ctlr->td[i].b);
			ctlr->td[i].b = nil;
		}
	}
}

static void
initrings(Ctlr *ctlr)
{
	u32int rcfg, tcfg, dmapri[3];
	int i;

	ctlr->rx->intregs = &ctlr->regs[Intrl0];
	ctlr->rx->intmask = IrqRxDmaDone;
	ctlr->rx->num = 16;
	rcfg = 1<<16;
	for(i = 1; i < nelem(ctlr->rx); i++){
		ctlr->rx[i].regs = &ctlr->regs[RdmaOffset + nelem(ctlr->rd)*3 + (i-1)*RingCfg];
		ctlr->rx[i].intregs = &ctlr->regs[Intrl1];
		ctlr->rx[i].intmask = 0x10000 << (i - 1);
		ctlr->rx[i].num = i - 1;
		rcfg |= 1<<(i-1);
	}
	assert(rcfg && (rcfg & ~RxRingCfgMask) == 0);

	ctlr->tx->intregs = &ctlr->regs[Intrl0];
	ctlr->tx->intmask = IrqTxDmaDone;
	ctlr->tx->num = 16;
	tcfg = 1<<16;
	for(i = 1; i < nelem(ctlr->tx); i++){
		ctlr->tx[i].regs = &ctlr->regs[TdmaOffset + nelem(ctlr->td)*3 + (i-1)*RingCfg];
		ctlr->tx[i].intregs = &ctlr->regs[Intrl1];
		ctlr->tx[i].intmask = 1 << (i - 1);
		ctlr->tx[i].num = i - 1;
		tcfg |= 1<<(i-1);
	}
	assert(tcfg && (tcfg & ~TxRingCfgMask) == 0);

	REG(ctlr->rx->regs[DmaScbBurstSize]) = 0x08;
	for(i = 1; i < nelem(ctlr->rx); i++)
		initring(&ctlr->rx[i], ctlr->rd, (i-1)*32, 32);
	initring(ctlr->rx, ctlr->rd, (i-1)*32, nelem(ctlr->rd) - (i-1)*32);

	for(i = 0; i < nelem(ctlr->rx); i++){		 
		REG(ctlr->rx[i].regs[DmaDoneThresh]) = 1;
		REG(ctlr->rx[i].regs[RdmaXonXoffThresh]) = (5 << 16) | ((ctlr->rx[i].m+1) >> 4);

		/* set dma timeout to 50us */
		REG(ctlr->rx->regs[RdmaTimeout0 + ctlr->rx[i].num]) = ((50*1000 + 8191)/8192);
	}

	REG(ctlr->tx->regs[DmaScbBurstSize]) = 0x08;
	for(i = 1; i < nelem(ctlr->tx); i++)
		initring(&ctlr->tx[i], ctlr->td, (i-1)*32, 32);
	initring(ctlr->tx, ctlr->td, (i-1)*32, nelem(ctlr->td) - (i-1)*32);

	dmapri[0] = dmapri[1] = dmapri[2] = 0;
	for(i = 0; i < nelem(ctlr->tx); i++){
		REG(ctlr->tx[i].regs[DmaDoneThresh]) = 10;
		REG(ctlr->tx[i].regs[TdmaFlowPeriod]) = i ? 0 : Maxtu << 16;
		dmapri[ctlr->tx[i].num/6] |= i << ((ctlr->tx[i].num%6)*5);
	}

	REG(ctlr->tx->regs[TdmaArbCtrl]) = 2;
	REG(ctlr->tx->regs[TdmaPriority0]) = dmapri[0];
	REG(ctlr->tx->regs[TdmaPriority1]) = dmapri[1];
	REG(ctlr->tx->regs[TdmaPriority2]) = dmapri[2];

	REG(ctlr->rx->regs[RingCfg]) = rcfg;
	REG(ctlr->tx->regs[RingCfg]) = tcfg;

	REG(ctlr->rx->regs[DmaCtrl]) |= rcfg<<1;
	REG(ctlr->tx->regs[DmaCtrl]) |= tcfg<<1;
}

static void
umaccmd(Ctlr *ctlr, u32int set, u32int clr)
{
	ilock(&ctlr->l);
	REG(ctlr->regs[UmacCmd]) = (REG(ctlr->regs[UmacCmd]) & ~clr) | set;
	iunlock(&ctlr->l);
}

static void
reset(Ctlr *ctlr)
{
	u32int r;

	/* reset umac */
	r = REG(ctlr->regs[SysRbufFlushCtrl]);
	REG(ctlr->regs[SysRbufFlushCtrl]) = r | 2;
	microdelay(10);
	REG(ctlr->regs[SysRbufFlushCtrl]) = r & ~2;
	microdelay(10);

	/* umac reset */
	REG(ctlr->regs[SysRbufFlushCtrl]) = 0;
	microdelay(10);

	REG(ctlr->regs[UmacCmd]) = 0;
	REG(ctlr->regs[UmacCmd]) = CmdSwReset | CmdLclLoopEn;
	microdelay(2);
	REG(ctlr->regs[UmacCmd]) = 0;
}

static void
setmac(Ctlr *ctlr, uchar *ea)
{
	REG(ctlr->regs[UmacMac0]) = ea[0]<<24 | ea[1]<<16 | ea[2]<<8 | ea[3];
	REG(ctlr->regs[UmacMac1]) = ea[4]<<8 | ea[5];
}

static void
sethfb(Ctlr *ctlr)
{
	int i;

	REG(ctlr->regs[HfbCtlr]) = 0;
	REG(ctlr->regs[HfbFltEnable]) = 0;
	REG(ctlr->regs[HfbFltEnable+1]) = 0;

	for(i = 0; i < 8; i++)
		REG(ctlr->rx->regs[RdmaIndex2Ring0+i]) = 0;

	for(i = 0; i < 48/4; i++)
		REG(ctlr->regs[HfbFltLen + i]) = 0;

	for(i = 0; i < 48*128; i++)
		REG(ctlr->regs[HfbOffset + i]) = 0;
}

static int
mdiodone(void *arg)
{
	Ctlr *ctlr = arg;
	REG(ctlr->regs[Intrl0 + IntrMaskClr]) = (IrqMdioDone|IrqMdioError);
	return (REG(ctlr->regs[MdioCmd]) & MdioStartBusy) == 0;
}

/*
 * The original waits as long as the busy bit is set. A second is a
 * thousand MDIO transactions; after that the bus is not going to
 * answer and the PHY scan above this must be allowed to fail.
 */
static int
mdiowait(Ctlr *ctlr)
{
	int i;

	REG(ctlr->regs[MdioCmd]) |= MdioStartBusy;
	for(i = 0; REG(ctlr->regs[MdioCmd]) & MdioStartBusy; i++){
		if(i >= 100){
			ctlr->nmdiotimeout++;
			return -1;
		}
		tsleep(ctlr->miir, mdiodone, ctlr, 10);
	}
	return 0;
}

static int
mdiow(Mii* mii, int phy, int addr, int data)
{
	Ctlr *ctlr = mii->ctlr;

	if(phy > MdioPhyMask)
		return -1;
	addr &= MdioAddrMask;
	REG(ctlr->regs[MdioCmd]) = MdioWrite
		| (phy << MdioPhyShift) | (addr << MdioAddrShift) | (data & 0xFFFF);
	return mdiowait(ctlr);
}

static int
mdior(Mii* mii, int phy, int addr)
{
	Ctlr *ctlr = mii->ctlr;

	if(phy > MdioPhyMask)
		return -1;
	addr &= MdioAddrMask;
	REG(ctlr->regs[MdioCmd]) = MdioRead
		| (phy << MdioPhyShift) | (addr << MdioAddrShift);
	if(mdiowait(ctlr) < 0)
		return -1;
	if(REG(ctlr->regs[MdioCmd]) & MdioReadFail)
		return -1;
	return REG(ctlr->regs[MdioCmd]) & 0xFFFF;
}

static int
bcmshdr(MiiPhy *phy, int reg)
{
	miimiw(phy, 0x1C, (reg & 0x1F) << 10);
	return miimir(phy, 0x1C) & 0x3FF;
}

static int
bcmshdw(MiiPhy *phy, int reg, int dat)
{
	return miimiw(phy, 0x1C, 0x8000 | (reg & 0x1F) << 10 | (dat & 0x3FF));
}

static int
linkevent(void *arg)
{
	Ctlr *ctlr = arg;
	REG(ctlr->regs[Intrl0 + IntrMaskClr]) = IrqLinkUp|IrqLinkDown;
	return 0;
}

static void
linkproc(void *arg)
{
	Ether *edev = arg;
	Ctlr *ctlr = edev->ctlr;
	MiiPhy *phy;
	int link = -1;

	while(waserror())
		;

	for(;;){
		tsleep(ctlr->link, linkevent, ctlr, 1000);
		phy = ctlr->mii->curphy;
		if(phy == nil)
			continue;
		miistatus(phy);
		if(phy->link == link)
			continue;
		link = phy->link;
		if(link){
			u32int cmd = CmdRxEn|CmdTxEn;
			switch(phy->speed){
			case 1000:	cmd |= CmdSpeed1000; break;
			case 100:	cmd |= CmdSpeed100; break;
			case 10:	cmd |= CmdSpeed10; break;
			}
			if(!phy->fd)
				cmd |= CmdHdEn;
			if(!phy->rfc)
				cmd |= CmdRxPauseIgn;
			if(!phy->tfc)
				cmd |= CmdTxPauseIgn;

			REG(ctlr->regs[ExtRgmiiOobCtrl]) = (REG(ctlr->regs[ExtRgmiiOobCtrl]) & ~OobDisable) | RgmiiLink;
			umaccmd(ctlr, cmd, CmdSpeedMask|CmdHdEn|CmdRxPauseIgn|CmdTxPauseIgn);

			edev->nif.mbps = phy->speed;
			print("genet: link up, %dMbit/s %s duplex\n", phy->speed, phy->fd ? "full" : "half");
		}else
			print("genet: link down\n");
		edev->nif.link = link;
	}
}

static void
setmdfaddr(Ctlr *ctlr, int i, uchar *ea)
{
	REG(ctlr->regs[UmacMdfAddr0 + i*2 + 0]) = ea[0] << 8  | ea[1];
	REG(ctlr->regs[UmacMdfAddr0 + i*2 + 1]) = ea[2] << 24 | ea[3] << 16 | ea[4] << 8 | ea[5];
}

static void
rxmode(Ether *edev, int prom)
{
	Ctlr *ctlr = edev->ctlr;
	Netaddr *na;
	int i;

	if(prom || edev->nif.nmaddr > 16-2){
		REG(ctlr->regs[UmacMdfCtrl]) = 0;
		umaccmd(ctlr, CmdProm, 0);
		return;
	}
	setmdfaddr(ctlr, 0, edev->nif.bcast);
	setmdfaddr(ctlr, 1, edev->ea);
	for(i = 2, na = edev->nif.maddr; na != nil; na = na->next, i++)
		setmdfaddr(ctlr, i, na->addr);
	/* the top i of the 17 filter-enable bits; the original shifts a negative int */
	REG(ctlr->regs[UmacMdfCtrl]) = ((u32int)0xFFFF0000 >> i) & 0x1FFFF;
	umaccmd(ctlr, 0, CmdProm);
}

static void
shutdown(Ether *edev)
{
	Ctlr *ctlr = edev->ctlr;

	dmaoff(ctlr);
	introff(ctlr);
}

static void
attach(Ether *edev)
{
	Ctlr *ctlr = edev->ctlr;
	MiiPhy *phy;

	qlock(&ctlr->alock);
	if(ctlr->attached){
		qunlock(&ctlr->alock);
		return;
	}
	if(waserror()){
		print("#l%d: genet: %s\n", edev->ctlrno, up->env->errstr);
		delmiibus(ctlr->mii);
		shutdown(edev);
		freebufs(ctlr);
		qunlock(&ctlr->alock);
		nexterror();
	}

	/* statistics */
	REG(ctlr->regs[UmacMibCtrl]) = MibResetRx | MibResetTx | MibResetRunt;
	REG(ctlr->regs[UmacMibCtrl]) = 0;

	/* wol */
	REG(ctlr->regs[UmacMpdCtrl]) &= ~(MpdPwEn|MpdEn);

	/* power */
	REG(ctlr->regs[UmacEeeCtrl]) &= ~UmacEeeEn;
	REG(ctlr->regs[RbufEnergyCtrl]) &= ~(RbufEeeEn|RbufPmEn);
	REG(ctlr->regs[TbufEnergyCtrl]) &= ~(RbufEeeEn|RbufPmEn);
	REG(ctlr->regs[TbufBpMc]) = 0;

	REG(ctlr->regs[UmacMaxFrameLen]) = Maxtu;

	REG(ctlr->regs[RbufTbufSizeCtrl]) = 1;

	REG(ctlr->regs[TbufCtrl]) &= ~(Rbuf64En);
	REG(ctlr->regs[RbufCtrl]) &= ~(Rbuf64En|RbufAlign2B);
	REG(ctlr->regs[RbufChkCtrl]) &= ~(RbufChkRxChkEn|RbufChkSkipFcs);

	allocbufs(ctlr);
	initrings(ctlr);
	if(dmaon(ctlr) < 0)
		error("DMA would not start");

	setmac(ctlr, edev->ea);
	sethfb(ctlr);
	rxmode(edev, 0);

	REG(ctlr->regs[SysPortCtrl]) = PortModeExtGphy;
	REG(ctlr->regs[ExtRgmiiOobCtrl]) |= RgmiiModeEn | IdModeDis;

	ctlr->mii->name = ctlr->name;
	ctlr->mii->ctlr = ctlr;
	ctlr->mii->mir = mdior;
	ctlr->mii->miw = mdiow;
	addmiibus(ctlr->mii);

	mii(ctlr->mii, ~0);
	phy = ctlr->mii->curphy;
	if(phy == nil)
		error("no phy");

	print("#l%d: genet: phy%d id %.8ux oui %x\n",
		edev->ctlrno, phy->phyno, phy->id, phy->oui);

	miireset(phy);

	switch(phy->id){
	case 0x600d84a2:	/* BCM54312PE */
		/* mask interrupts */
		miimiw(phy, 0x10, miimir(phy, 0x10) | 0x1000);

		/* SCR3: clear DLLAPD_DIS */
		bcmshdw(phy, 0x05, bcmshdr(phy, 0x05) &~0x0002);
		/* APD: set APD_EN */
		bcmshdw(phy, 0x0a, bcmshdr(phy, 0x0a) | 0x0020);

		/* blinkenlights */
		bcmshdw(phy, 0x09, bcmshdr(phy, 0x09) | 0x0010);
		bcmshdw(phy, 0x0d, 3<<0 | 0<<4);
		break;
	}

	/* don't advertise EEE */
	miimmdw(phy, 7, 60, 0);

	miiane(phy, ~0, AnaAP|AnaP, ~0);

	ctlr->attached = 1;

	kproc("genet-recv", recvproc, edev, 0);
	kproc("genet-send", sendproc, edev, 0);
	kproc("genet-free", freeproc, edev, 0);
	kproc("genet-link", linkproc, edev, 0);

	qunlock(&ctlr->alock);
	poperror();
}

static void
prom(void *arg, int on)
{
	Ether *edev = arg;
	rxmode(edev, on);
}

static void
multi(void *arg, uchar *addr, int on)
{
	Ether *edev = arg;

	USED(addr);
	USED(on);
	rxmode(edev, edev->nif.prom > 0);
}

static long
genetifstat(Ether *edev, void *a, long n, ulong off)
{
	Ctlr *ctlr = edev->ctlr;
	MiiPhy *phy;
	char *p;
	int l;

	p = malloc(READSTR);
	if(p == nil)
		error(Enomem);
	phy = ctlr->mii->curphy;
	l = snprint(p, READSTR,
		"genet rev %#ux at %#p irq %d,%d %s\n"
		"intr0 %lud intr1 %lud rx %lud rxbad %lud tx %lud nobuf %lud mdiotimeout %lud\n"
		"rx rp %ud wp %ud tx cp %ud rp %ud wp %ud oq %d\n",
		ctlr->rev, ctlr->regs, IRQether, IRQether+1, ctlr->attached ? "attached" : "not attached",
		ctlr->nintr0, ctlr->nintr1, ctlr->nrx, ctlr->nrxbad, ctlr->ntx, ctlr->nnobuf, ctlr->nmdiotimeout,
		ctlr->rx->rp, ctlr->rx->wp, ctlr->tx->cp, ctlr->tx->rp, ctlr->tx->wp, qlen(edev->oq));
	if(phy != nil)
		snprint(p+l, READSTR-l, "phy%d id %.8ux link %d speed %d %s duplex\n",
			phy->phyno, phy->id, phy->link, phy->speed, phy->fd ? "full" : "half");
	else
		snprint(p+l, READSTR-l, "no phy\n");
	n = readstr(off, a, n, p);
	free(p);
	return n;
}

/*
 * Called from socdevprobe (soc.c) at board init: after devether's reset
 * has made instance 0, before anything can bind #l, in kmain, with no
 * scheduler -- so nothing here sleeps. 9front's pnp(), preceded by the
 * question of whether there is a GENET to talk to at all.
 *
 * If there is, it is ether0 and osinit finds a kernel link driver there
 * (a MAC address that is not zeros) and configures it. If there is not,
 * instance 0 is left exactly as it was: the USB Ethernet path's.
 */
void
ethergenetlink(void)
{
	static Ctlr ctlr[1];
	Ether *edev;
	u32int rev;

	if(ctlr->regs != nil)
		return;
	if(probe32(GENETREGS + 4*SysRevision, &rev) < 0){
		print("genet: NO ETHERNET MAC AT %#ux -- an emulator; ether0 is left to USB\n", GENETREGS);
		return;
	}
	/* GENETv5 reports major revision 6 (Linux's bcmgenet.c explains, after a fashion) */
	if(((rev >> 24) & 0xF) != 6){
		print("genet: revision register at %#ux reads %#ux, not a GENETv5's -- not touching it; ether0 is left to USB\n",
			GENETREGS, rev);
		return;
	}
	edev = etherinstance(0);
	if(edev == nil)
		return;

	ctlr->rev = rev;
	ctlr->regs = (u32int*)GENETREGS;
	ctlr->rx->regs = &ctlr->regs[RdmaOffset + nelem(ctlr->rd)*3 + 16*RingCfg];
	ctlr->tx->regs = &ctlr->regs[TdmaOffset + nelem(ctlr->td)*3 + 16*RingCfg];
	snprint(ctlr->name, sizeof ctlr->name, "ether%d", edev->ctlrno);

	if(getmacaddr(edev->ea) < 0){
		print("genet: the firmware would not say what this board's MAC address is\n");
		ctlr->regs = nil;
		return;
	}
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
	edev->ifstat = genetifstat;
	edev->shutdown = shutdown;

	reset(ctlr);
	dmaoff(ctlr);
	introff(ctlr);

	intrenable(IRQether+0, interrupt0, edev, 0, "genet");
	intrenable(IRQether+1, interrupt1, edev, 0, "genet1");

	print("genet: rev %#ux %2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux is #l (ether0)\n", rev,
		edev->ea[0], edev->ea[1], edev->ea[2], edev->ea[3], edev->ea[4], edev->ea[5]);
}
