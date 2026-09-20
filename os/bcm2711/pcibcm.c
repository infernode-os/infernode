/*
 * The BCM2711's PCIe host bridge (Broadcom's "bcmstb" root complex):
 * one lane, one slot, and on a Raspberry Pi 4 one device soldered to
 * it -- the VL805 xHCI controller that the four USB-A sockets hang off.
 *
 * Derived from 9front's sys/src/9/bcm64/pcibcm.c (MIT: Copyright © 2021
 * Plan 9 Foundation, Copyright © 9front authors); ../port/pci.c, also
 * 9front's, does the enumeration.
 *
 * NOT ONE LINE OF THIS FILE HAS EVER EXECUTED AGAINST THE BRIDGE.
 * QEMU's raspi4b has no PCIe and there is no board. What HAS run is
 * everything above it: ../port/pci.c and the xHCI driver are exercised
 * on QEMU's `virt` machine through ../virt/pciecam.c. So this file is
 * kept as near the original as possible -- the reset sequence, the
 * window registers and the MSI arrangement are 9front's exactly -- and
 * differs only as follows:
 *
 *   Registers are volatile; Plan 9's compilers do not need telling.
 *
 *   It asks before it touches. The bridge's revision register is read
 *   through probe32 (../arm64/trap.c); an abort means an emulator, and
 *   says so.
 *
 *   pciintrenable takes the Pcidev and returns a verdict: this tree's
 *   contract (../port/pci.h), since intrenable here has no tbdf route
 *   to a bus driver.
 *
 *   The VL805's firmware is asked for here, after the bus scan, rather
 *   than in a separate arch link: the firmware resets PCIe before it
 *   starts the kernel, the VL805 loses what it was running, and on
 *   boards without the VL805's own EEPROM only the VideoCore can put it
 *   back (mailbox tag 0x00030058).
 *
 * ADDRESSES, BOTH WAYS.
 *
 * Outbound -- the CPU reaching a device's registers -- is a window at
 * CPU address 0x6_0000_0000, 24GB up, which ../bcm/mmu.c maps as one
 * Device gigabyte (PCIWIN in mem.h, which also raises the MMU's
 * physical address size: the BCM2837's 32 bits do not reach it). The
 * PCI side of the window has the same address, so a BAR holds what the
 * CPU uses.
 *
 * Inbound -- a device reaching memory -- is one gigabyte at PCI address
 * 0 onto physical address 0: 9front's choice, and the same limit the
 * rest of this SoC's DMA masters have (../bcm/dmamem.c). So what a PCI
 * device is given must come from dmaalloc() or be bounced, and
 * pcibusaddr() is busaddr(): it PANICS on an address the device could
 * not reach, under emulation as on a board. Early VL805 boards cannot
 * reach above 3GB whatever the bridge says, so widening this is not
 * just a register.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/pci.h"
#include "board.h"

#define delay(ms)	microdelay((ms)*1000)

/* bcmstb PCIe controller registers */
enum{
	RC_CFG_VENDOR_VENDOR_SPECIFIC_REG1	= 0x0188/4,
	RC_CFG_PRIV1_ID_VAL3			= 0x043c/4,
	RC_DL_MDIO_ADDR				= 0x1100/4,
	RC_DL_MDIO_WR_DATA			= 0x1104/4,
	RC_DL_MDIO_RD_DATA			= 0x1108/4,
	MISC_MISC_CTRL				= 0x4008/4,
	MISC_CPU_2_PCIE_MEM_WIN0_LO		= 0x400c/4,
	MISC_CPU_2_PCIE_MEM_WIN0_HI		= 0x4010/4,
	MISC_RC_BAR1_CONFIG_LO			= 0x402c/4,
	MISC_RC_BAR2_CONFIG_LO			= 0x4034/4,
	MISC_RC_BAR2_CONFIG_HI			= 0x4038/4,
	MISC_RC_BAR3_CONFIG_LO			= 0x403c/4,
	MISC_MSI_BAR_CONFIG_LO			= 0x4044/4,
	MISC_MSI_BAR_CONFIG_HI			= 0x4048/4,
	MISC_MSI_DATA_CONFIG			= 0x404c/4,
	MISC_EOI_CTRL				= 0x4060/4,
	MISC_PCIE_CTRL				= 0x4064/4,
	MISC_PCIE_STATUS			= 0x4068/4,
	MISC_REVISION				= 0x406c/4,
	MISC_CPU_2_PCIE_MEM_WIN0_BASE_LIMIT	= 0x4070/4,
	MISC_CPU_2_PCIE_MEM_WIN0_BASE_HI	= 0x4080/4,
	MISC_CPU_2_PCIE_MEM_WIN0_LIMIT_HI	= 0x4084/4,
	MISC_HARD_PCIE_HARD_DEBUG		= 0x4204/4,

	INTR2_CPU_BASE				= 0x4300/4,
	MSI_INTR2_BASE				= 0x4500/4,
		INTR_STATUS = 0,
		INTR_SET,
		INTR_CLR,
		INTR_MASK_STATUS,
		INTR_MASK_SET,
		INTR_MASK_CLR,

	EXT_CFG_INDEX				= 0x9000/4,
	RGR1_SW_INIT_1				= 0x9210/4,
	EXT_CFG_DATA				= 0x8000/4,

};

#define MSI_TARGET_ADDR		0xFFFFFFFFCULL

enum
{
	TagXhcireset	= 0x00030058,	/* "notify xHCI reset": load the VL805's firmware */

	Vl805vid	= 0x1106,
	Vl805did	= 0x3483,
};

static volatile u32int *regs = (u32int*)PCIEREGS;
static Pcidev* pciroot;
static int linkup;

static void*
cfgaddr(int tbdf, int rno)
{
	if(BUSBNO(tbdf) == 0 && BUSDNO(tbdf) == 0)
		return (uchar*)regs + rno;
	/*
	 * Anything else is across the link. With the link down that is
	 * an abort, not an empty slot, and pcibcmlink never scans then;
	 * this is for whoever calls later.
	 */
	if(!linkup)
		return nil;
	regs[EXT_CFG_INDEX] = BUSBNO(tbdf) << 20 | BUSDNO(tbdf) << 15 | BUSFNO(tbdf) << 12;
	coherence();
	return ((uchar*)&regs[EXT_CFG_DATA]) + rno;
}

int
pcicfgrw32(int tbdf, int rno, int data, int read)
{
	volatile u32int *p;

	if((p = cfgaddr(tbdf, rno & ~3)) != nil){
		if(read)
			data = *p;
		else
			*p = data;
	} else {
		data = -1;
	}
	return data;
}

int
pcicfgrw16(int tbdf, int rno, int data, int read)
{
	volatile u16int *p;

	if((p = cfgaddr(tbdf, rno & ~1)) != nil){
		if(read)
			data = *p;
		else
			*p = data;
	} else {
		data = -1;
	}
	return data;
}

int
pcicfgrw8(int tbdf, int rno, int data, int read)
{
	volatile u8int *p;

	if((p = cfgaddr(tbdf, rno)) != nil){
		if(read)
			data = *p;
		else
			*p = data;
	} else {
		data = -1;
	}
	return data;
}

typedef struct Pciisr Pciisr;
struct Pciisr {
	void	(*f)(Ureg*, void*);
	void	*a;
	Pcidev	*p;
};

static Pciisr pciisr[32];
static Lock pciisrlk;

/*
 * Interrupts are messages: the device writes a number to
 * MSI_TARGET_ADDR, the bridge catches the write and sets that bit in
 * MSI_INTR2, and all 32 bits are one GIC interrupt.
 */
int
pciintrenable(Pcidev *p, void (*f)(Ureg*, void*), void *a, char *name)
{
	ulong dat;
	Pciisr *isr;

	if(pcimsidisable(p) < 0){
		print("pci: %T: %s does not support MSI, and this bridge delivers nothing else\n", p->tbdf, name);
		return -1;
	}

	ilock(&pciisrlk);
	for(isr = pciisr; isr < &pciisr[nelem(pciisr)]; isr++){
		if(isr->p == p){
			isr->p = nil;
			regs[MSI_INTR2_BASE + INTR_MASK_SET] = 1 << (isr-pciisr);
			break;
		}
	}
	for(isr = pciisr; isr < &pciisr[nelem(pciisr)]; isr++){
		if(isr->p == nil){
			isr->p = p;
			isr->a = a;
			isr->f = f;
			regs[MSI_INTR2_BASE + INTR_CLR] = 1 << (isr-pciisr);
			regs[MSI_INTR2_BASE + INTR_MASK_CLR] = 1 << (isr-pciisr);
			break;
		}
	}
	iunlock(&pciisrlk);

	if(isr >= &pciisr[nelem(pciisr)]){
		print("pci: %T: %s: out of MSI slots\n", p->tbdf, name);
		return -1;
	}

	dat = regs[MISC_MSI_DATA_CONFIG];
	dat = ((dat >> 16) & (dat & 0xFFFF)) | (isr-pciisr);
	pcimsienable(p, MSI_TARGET_ADDR, dat);
	p->intl = IRQpci;
	return 0;
}

static void
pciinterrupt(Ureg *ureg, void *a)
{
	Pciisr *isr;
	u32int sts;

	USED(a);
	sts = regs[MSI_INTR2_BASE + INTR_STATUS];
	if(sts == 0)
		return;
	regs[MSI_INTR2_BASE + INTR_CLR] = sts;
	for(isr = pciisr; sts != 0 && isr < &pciisr[nelem(pciisr)]; isr++, sts>>=1){
		if((sts & 1) != 0 && isr->f != nil)
			(*isr->f)(ureg, isr->a);
	}
	regs[MISC_EOI_CTRL] = 1;
}

u64int
pcibusaddr(void *va)
{
	/* busaddr() is the check against DMATOP; its VideoCore alias bits are not PCI's */
	return busaddr((uintptr)va) & ~0xC0000000ULL;
}

/* the SoC's DMA arena and its limit: ../bcm/dmamem.c */
void*
pcidmaalloc(ulong size, int align)
{
	return dmaalloc(size, align);
}

void
pcidmafree(void *p, ulong size)
{
	dmafree(p, size);
}

int
pcidmaok(void *va, ulong len)
{
	return dmareachable(va, len);
}

static void
pcicfginit(void)
{
	uvlong base, limit;
	ulong ioa;

	fmtinstall('T', tbdffmt);

	pciscan(0, &pciroot, nil);
	if(pciroot == nil)
		return;

	/*
	 * Work out how big the top bus is
	 */
	ioa = 0;
	base = PCIWIN;
	pcibusmap(pciroot, &base, &ioa, 0);
	limit = base-1;

	/*
	 * Align the windows and map it
	 */
	base = PCIWIN;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_LO] = base;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_HI] = base >> 32;
	base >>= 20, limit >>= 20;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_BASE_LIMIT] = (base & 0xFFF) << 4 | (limit & 0xFFF) << 20;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_BASE_HI] = base >> 12;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_LIMIT_HI] = limit >> 12;

	ioa = 0;
	base = PCIWIN;
	pcibusmap(pciroot, &base, &ioa, 1);

	pcihinv(pciroot);
}

/*
 * After a PCIe reset the VL805 has no firmware. The VideoCore will
 * load it, given the device's address in configuration-space form.
 * Boards whose VL805 has an EEPROM of its own do not need this and are
 * not harmed by it.
 */
static void
vl805firmware(void)
{
	Pcidev *p;
	u32int buf[1];

	if((p = pcimatch(nil, Vl805vid, Vl805did)) == nil){
		print("pci: no VL805 -- a Compute Module, or a board this file has not met\n");
		return;
	}
	buf[0] = BUSBNO(p->tbdf)<<20 | BUSDNO(p->tbdf)<<15 | BUSFNO(p->tbdf)<<12;
	if(mboxprop(TagXhcireset, buf, 1, 1) < 0)
		print("pci: %T: the firmware would not reload the VL805 (mailbox tag %#ux); USB may be dead\n",
			p->tbdf, TagXhcireset);
	else
		print("pci: %T: VL805 firmware reload requested, answer %#ux\n", p->tbdf, buf[0]);
}

/*
 * Called from socdevprobe (soc.c): board init, in kmain, no scheduler.
 * The delays are 9front's and add up to 1.1s.
 */
void
pcibcmlink(void)
{
	int log2dmasize = 30;	/* 1GB: DMATOP */
	u32int rev;

	if(probe32(PCIEREGS + 4*MISC_REVISION, &rev) < 0){
		print("pci: NO PCIe BRIDGE AT %#ux -- an emulator; no xHCI, so no USB-A sockets\n", PCIEREGS);
		return;
	}
	print("pci: bcmstb bridge revision %#ux\n", rev);

	regs[RGR1_SW_INIT_1] |= 3;
	delay(200);
	regs[RGR1_SW_INIT_1] &= ~2;
	regs[MISC_PCIE_CTRL] &= ~5;
	delay(200);

	regs[MISC_HARD_PCIE_HARD_DEBUG] &= ~0x08000000;
	delay(200);

	regs[MSI_INTR2_BASE + INTR_CLR] = -1;
	regs[MSI_INTR2_BASE + INTR_MASK_SET] = -1;

	regs[MISC_CPU_2_PCIE_MEM_WIN0_LO] = 0;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_HI] = 0;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_BASE_LIMIT] = 0;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_BASE_HI] = 0;
	regs[MISC_CPU_2_PCIE_MEM_WIN0_LIMIT_HI] = 0;

	/* SCB_ACCESS_EN, CFG_READ_UR_MODE, MAX_BURST_SIZE_128, SCB0SIZE */
	regs[MISC_MISC_CTRL] = 1<<12 | 1<<13 | 0<<20 | (log2dmasize-15)<<27;

	/* the inbound window: PCI address 0, onto physical address 0 */
	regs[MISC_RC_BAR2_CONFIG_LO] = 0 | (log2dmasize-15);
	regs[MISC_RC_BAR2_CONFIG_HI] = 0;

	regs[MISC_RC_BAR1_CONFIG_LO] = 0;
	regs[MISC_RC_BAR3_CONFIG_LO] = 0;

	regs[MISC_MSI_BAR_CONFIG_LO] = MSI_TARGET_ADDR | 1;
	regs[MISC_MSI_BAR_CONFIG_HI] = MSI_TARGET_ADDR>>32;
	regs[MISC_MSI_DATA_CONFIG] = 0xFFF86540;
	intrenable(IRQpci, pciinterrupt, nil, 0, "pci");

	/* force to GEN2 */
	regs[(0xAC + 12)/4] = (regs[(0xAC + 12)/4] & ~15) | 2;	/* linkcap */
	regs[(0xAC + 48)/4] = (regs[(0xAC + 48)/4] & ~15) | 2;	/* linkctl2 */

	regs[RGR1_SW_INIT_1] &= ~1;
	delay(500);

	if((regs[MISC_PCIE_STATUS] & 0x30) != 0x30){
		print("pci: THE PCIe LINK IS DOWN (status %#ux) -- nothing beyond the bridge, so no USB-A sockets\n",
			regs[MISC_PCIE_STATUS]);
		return;
	}
	linkup = 1;

	regs[RC_CFG_PRIV1_ID_VAL3] = 0x060400;
	regs[RC_CFG_VENDOR_VENDOR_SPECIFIC_REG1] &= ~0xC;
	regs[MISC_HARD_PCIE_HARD_DEBUG] |= 2;

	pcicfginit();
	vl805firmware();
}
