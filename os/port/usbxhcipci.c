/*
 * An xHCI controller on a PCI bus: finding it, and the three things
 * that are the bus's and not the controller's -- where its registers
 * are, how its interrupt arrives, and what address memory has from its
 * side.
 *
 * After 9front's sys/src/9/port/usbxhcipci.c (MIT: Copyright © 2021
 * Plan 9 Foundation, Copyright © 9front authors). Its vmap() is a cast
 * here, because both machines that have PCI map their windows at boot
 * (../virt/mmu.c, ../bcm/mmu.c); its interrupt goes through the bridge's
 * pciintrenable() and not devusb's intrenable(), which is told to keep
 * out by an irq below zero; and the bridge says what a device's view of
 * memory is (pcibusaddr).
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

#include	"usbxhci.h"

static Xhci *ctlrs[Nhcis];

static void
scanpci(void)
{
	static int already = 0;
	int i;
	u64int io, iosize;
	Xhci *ctlr;
	Pcidev *p;

	if(already)
		return;
	already = 1;
	p = nil;
	while ((p = pcimatch(p, 0, 0)) != nil) {
		/*
		 * Find XHCI controllers (Programming Interface = 0x30).
		 */
		if(p->ccrb != Pcibcserial || p->ccru != Pciscusb || p->ccrp != 0x30)
			continue;
		if(p->mem[0].bar & 1)
			continue;
		iosize = p->mem[0].size;
		if(iosize == 0)
			continue;
		io = p->mem[0].bar & ~0x0fULL;
		if(io == 0)
			continue;
		print("usbxhci: %T: %.4ux:%.4ux registers at %#llux, %lld bytes\n",
			p->tbdf, p->vid, p->did, io, iosize);
		ctlr = xhcialloc((u32int*)(uintptr)io, io, iosize);
		if(ctlr == nil)
			continue;
		ctlr->aux = p;
		for(i = 0; i < nelem(ctlrs); i++)
			if(ctlrs[i] == nil){
				ctlrs[i] = ctlr;
				break;
			}
		if(i >= nelem(ctlrs))
			print("xhci: bug: more than %d controllers\n", nelem(ctlrs));
	}
}

static void
init(Hci *hp)
{
	Xhci *ctlr = hp->aux;
	Pcidev *pcidev = ctlr->aux;

	if(ctlr->mmio[0] == -1){
		pcidisable(pcidev);
		error("controller vanished");
	}
	pcisetbme(pcidev);
	xhciinit(hp);
}

static void
shutdown(Hci *hp)
{
	Xhci *ctlr = hp->aux;
	Pcidev *pcidev = ctlr->aux;

	xhcishutdown(hp);
	pcidisable(pcidev);
}

static int
reset(Hci *hp)
{
	Xhci *ctlr;
	Pcidev *pcidev;
	int i;

	scanpci();

	/*
	 * Any adapter matches if no hp->port is supplied,
	 * otherwise the ports must match.
	 */
	ctlr = nil;
	for(i = 0; i < nelem(ctlrs); i++){
		ctlr = ctlrs[i];
		if(ctlr == nil)
			break;
		if(ctlr->active == nil)
		if(hp->port == 0 || hp->port == ctlr->base)
			goto Found;
	}
	return -1;

Found:
	pcidev = ctlr->aux;
	pcienable(pcidev);
	xhcihandoff(ctlr);
	xhcilinkage(hp, ctlr);
	hp->init = init;
	hp->shutdown = shutdown;

	/*
	 * The handler is installed before init has made an event ring;
	 * interrupt() returns at once for a controller that has none,
	 * which on a shared line it must do anyway.
	 */
	if(pciintrenable(pcidev, hp->interrupt, hp, "usbxhci") < 0){
		print("usbxhci: %T: no interrupt, so no controller\n", pcidev->tbdf);
		ctlr->active = nil;
		return -1;
	}
	hp->irq = -1;		/* devusb: the interrupt is dealt with */
	hp->tbdf = pcidev->tbdf;
	return 0;
}

void
usbxhcipcilink(void)
{
	addhcitype("xhci", reset);
}
