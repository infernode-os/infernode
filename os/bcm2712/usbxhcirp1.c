/*
 * The USB ports: two DWC3 controllers in RP1, each an xHCI at the start
 * of its registers (../port/usbxhci.c), with the DesignWare global
 * registers above it. What ../port/usbxhcipci.c does for a controller
 * on a bus, for two that are simply there.
 *
 * They master RAM through the same bridge as the Ethernet MAC
 * (etherrp1.c). ../port/pci.h's memory contract is met by the SoC's DMA
 * arena (../bcm/dmamem.c), which is below 1GB, and so well below where
 * RP1 stops reaching; the bus address is the physical one.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/pci.h"
#include	"../port/error.h"
#include	"../port/usb.h"
#include	"../port/usbxhci.h"
#include	"board.h"

enum
{
	Usbsize		= 0x100000,
	Ncontrollers	= 2,

	Gctl		= 0xC110,	/* DesignWare global control */
		Prtcapmask	= 3<<12,
		Prtcaphost	= 1<<12,
	Gsnpsid		= 0xC120,
};

#define RP1REG(o)	(*(volatile u32int*)(uintptr)(RP1REGS + (o)))

static Xhci *ctlrs[Ncontrollers];

u64int
pcibusaddr(void *va)
{
	return busaddr((uintptr)va) & ~0xC0000000ULL;
}

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
hostmode(volatile u32int *mmio)
{
	mmio[Gctl/4] = (mmio[Gctl/4] & ~Prtcapmask) | Prtcaphost;
	coherence();
}

static int
reset(Hci *hp)
{
	Xhci *ctlr;
	int i;

	for(i = 0; i < Ncontrollers; i++){
		ctlr = ctlrs[i];
		if(ctlr != nil && ctlr->active == nil)
		if(hp->port == 0 || hp->port == ctlr->base)
			goto Found;
	}
	return -1;

Found:
	xhcihandoff(ctlr);
	xhcilinkage(hp, ctlr);
	hp->irq = -1;
	hp->tbdf = 0;
	rp1intrenable(i == 0 ? RP1intusb0 : RP1intusb1, hp->interrupt, hp, 0, "usbxhci");
	return 0;
}

void
usbxhcirp1link(void)
{
	static u64int base[Ncontrollers] = { RP1REGS + 0x200000, RP1REGS + 0x300000 };
	volatile u32int *mmio;
	int i;

	/* port power: RP1's GPIO 42 and 43, bank 2 pins 8 and 9, function 2 is VBUS_EN1, VBUS_OC1 */
	for(i = 8; i <= 9; i++){
		RP1REG(0xD8000 + 8*i + 4) = 2;
		RP1REG(0xF8000 + 4 + 4*i) = (RP1REG(0xF8000 + 4 + 4*i) | 1<<6) & ~(1<<7);
	}

	for(i = 0; i < Ncontrollers; i++){
		mmio = (u32int*)(uintptr)base[i];
		hostmode(mmio);
		ctlrs[i] = xhcialloc(mmio, base[i], Usbsize);
	}
	addhcitype("xhci", reset);
}
