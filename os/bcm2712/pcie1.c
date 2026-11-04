/*
 * The external PCIe connector: the SoC's second bridge. Unlike RP1's it
 * has nobody to set it up before us, so this does what Linux's
 * pcie-brcmstb.c and Circle's bcmpciehostbridge do: reset it, give it
 * the 54MHz reference, set the windows, and let the link train.
 *
 * Its reset is line 43. Line 44 is RP1's, which is the console. The
 * shared rescal block is left alone: RP1 is up, so it is too.
 *
 * Memory is at PCIe 0x10_0000_0000 + pa, all 64GB of it. Its devices'
 * registers are at CPU 0x1B80000000, PCIe 0x80000000, a gigabyte of
 * Linux's two. MSI goes to the second MIP.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"

#define B(o)		(*(volatile u32int*)(uintptr)(PCIE1REGS + (o)))
#define RST(o)		(*(volatile u32int*)(uintptr)(0x1001504318ULL + (o)))

enum
{
	Resetid		= 43,
	Resetbank	= 0x18*(Resetid>>5),
	Swinitset	= 0x00,
	Swinitclr	= 0x04,

	Vendorreg1	= 0x188,
	Idval3		= 0x43C,
	Mdioaddr	= 0x1100,
	Mdiowr		= 0x1104,
	Phyctl15	= 0x184C,
	Miscctrl	= 0x4008,
	Win0lo		= 0x400C,
	Win0hi		= 0x4010,
	Bar1lo		= 0x402C,
	Bar1hi		= 0x4030,
	Bar2lo		= 0x4034,
	Bar2hi		= 0x4038,
	Bar3lo		= 0x403C,
	Retrytimeout	= 0x405C,
	Pciectrl	= 0x4064,
		Perstb	= 1<<2,
	Pciestatus	= 0x4068,
		Plu	= 1<<4,
		Dla	= 1<<5,
		Rcmode	= 1<<7,
	Revision	= 0x406C,
	Win0limit	= 0x4070,
	Win0basehi	= 0x4080,
	Win0limhi	= 0x4084,
	Ubusctrl	= 0x40A4,
	Ubustimeout	= 0x40A8,
	Ubusbar1lo	= 0x40AC,
	Ubusbar1hi	= 0x40B0,
	Ubusbar2	= 0x40B4,
	Readerrdata	= 0x4170,
	Harddebug	= 0x4304,
		Iddq	= 1<<27,
		Clkreqdbg= 1<<1,
		L1ss	= 1<<21,
		Refclkovrden	= 1<<16,
		Refclkovrdout	= 1<<20,
	Rootcap		= 0x4F8,
	Extcfg		= 0x8000,
	Extcfgidx	= 0x9000,
	Lnkcap		= 0xAC + 0x0C,
	Lnkctl		= 0xAC + 0x10,	/* and link status, above it */
	Lnkctl2		= 0xAC + 0x30,

	Win		= 0x80000000,
	Winmb		= (int)(PCIE1WIN >> 20),
	Linktries	= 100,
};

static int
mdiow(int reg, u32int v)
{
	int i;

	B(Mdioaddr) = reg;
	(void)B(Mdioaddr);
	B(Mdiowr) = 1U<<31 | v;
	for(i = 0; i < 100; i++){
		if((B(Mdiowr) & 1U<<31) == 0)
			return 0;
		microdelay(10);
	}
	return -1;
}

static void
pll54(void)
{
	static uchar reg[] = {0x16, 0x17, 0x18, 0x19, 0x1B, 0x1C, 0x1E};
	static u16int val[] = {0x50B9, 0xBDA1, 0x0094, 0x97B4, 0x5030, 0x5030, 0x0007};
	int i;

	mdiow(0x1F, 0x1600);
	for(i = 0; i < nelem(reg); i++)
		mdiow(reg[i], val[i]);
	microdelay(200);
}

/* config space of the device behind the bridge */
u32int
pcie1cfgr(int off)
{
	B(Extcfgidx) = 1<<20;
	coherence();
	return B(Extcfg + off);
}

void
pcie1cfgw(int off, u32int v)
{
	B(Extcfgidx) = 1<<20;
	coherence();
	B(Extcfg + off) = v;
	coherence();
}

/* whether the link is there, now */
int
pcie1linked(void)
{
	return (B(Pciestatus) & (Plu|Dla)) == (Plu|Dla);
}

/* down to gen 1, and retrain */
void
pcie1slow(void)
{
	B(Lnkctl2) = (B(Lnkctl2) & ~0xFU) | 1;
	coherence();
	B(Lnkctl) |= 1<<5;
	coherence();
}

/* what it runs at, by the bridge's own link status */
char*
pcie1speed(void)
{
	switch(B(Lnkctl) >> 16 & 0xF){
	case 1:
		return "PCIe gen 1";
	case 2:
		return "PCIe gen 2";
	}
	return "PCIe link down";
}

int
pcie1up(void)
{
	u32int s, m;
	int i;

	RST(Resetbank + Swinitset) = 1<<(Resetid&31);
	coherence();
	microdelay(200);
	RST(Resetbank + Swinitclr) = 1<<(Resetid&31);
	coherence();
	microdelay(200);

	B(Harddebug) &= ~(u32int)Iddq;
	microdelay(200);
	pll54();
	B(Phyctl15) = (B(Phyctl15) & ~0xFFU) | 0x12;	/* the 18.52ns PM clock */

	m = B(Miscctrl);
	m &= ~(3U<<20 | 0x1FU<<27);
	m |= 1<<12 | 1<<13 | 1<<10 | 1<<20 | 0x15U<<27;	/* SCB access, UR mode, RCB MPS, 256 bursts, 64GB */
	B(Miscctrl) = m;

	B(Bar2lo) = 0x15;
	B(Bar2hi) = 0x10;
	B(Ubusbar2) |= 1;
	B(Bar3lo) = 0;

	B(Ubusctrl) |= 1<<13 | 1<<19;		/* read errors give ones, not aborts */
	B(Readerrdata) = ~0;
	B(Ubustimeout) = 0xB2D0000;
	B(Retrytimeout) = 0xABA0000;

	B(Bar1lo) = 0xFFFFF000 | 0x1C;		/* MSI: the MIP */
	B(Bar1hi) = 0xFF;
	B(Ubusbar1lo) = 0x00131000 | 1;
	B(Ubusbar1hi) = 0x10;

	/*
	 * Gen 2. On the bench the link trains, carries 370MB/s, drops once
	 * about 1.6s later, as it also did under Linux on this board, and
	 * comes straight back, the drive having lost its configuration;
	 * nvme.c recovers that, and it has then held under load. A link
	 * that keeps doing it is sent to gen 1: pcie1slow. pciegen1 is for
	 * asking for that from the start.
	 */
	i = cmdlineword("pciegen1") ? 1 : 2;
	B(Lnkcap) = (B(Lnkcap) & ~0xFU) | i;
	B(Lnkctl2) = (B(Lnkctl2) & ~0xFU) | i;
	B(Idval3) = (B(Idval3) & ~0xFFFFFFU) | 0x060400;

	B(Win0lo) = Win;
	B(Win0hi) = 0;
	B(Win0limit) = (u32int)((Winmb & 0xFFF) << 4) | (u32int)(((Winmb + 1023) & 0xFFF) << 20);
	B(Win0basehi) = Winmb >> 12;
	B(Win0limhi) = (Winmb + 1023) >> 12;
	B(Vendorreg1) &= ~(u32int)(3<<2);	/* little-endian */

	B(Pciectrl) |= Perstb;
	coherence();
	microdelay(100000);
	for(i = 0; i < Linktries; i++){
		s = B(Pciestatus);
		if((s & (Plu|Dla)) == (Plu|Dla))
			break;
		microdelay(10000);
	}
	s = B(Pciestatus);
	if((s & (Plu|Dla)) != (Plu|Dla)){
		print("pcie1: no link: nothing on the connector\n");
		return -1;
	}
	if((s & Rcmode) == 0){
		print("pcie1: not in root complex mode\n");
		return -1;
	}
	/*
	 * The device tree's clkreq-mode "safe": the reference clock is
	 * forced on, because a drive left to idle otherwise loses it and
	 * the link with it, and every read then answers ones.
	 */
	B(Harddebug) = (B(Harddebug) & ~(u32int)(Clkreqdbg|L1ss)) | Refclkovrden | Refclkovrdout;
	B(Rootcap) = (B(Rootcap) & ~0xF8U) | 2<<3;

	/* the bridge */
	B(0x18) = (B(0x18) & 0xFF000000) | 1<<16 | 1<<8;
	B(0x20) = Win >> 16 | (Win >> 16) << 16;
	B(4) = (B(4) & 0xFFFF) | 6;
	coherence();
	return 0;
}
