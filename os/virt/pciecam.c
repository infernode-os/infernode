/*
 * The PCIe host bridge of QEMU's `virt` machine: a generic ECAM host,
 * which is to say no hardware at all -- configuration space is an
 * array in memory, indexed by bus, device and function, and a device's
 * interrupt is one of four wires into the GIC.
 *
 * After 9front's sys/src/9/arm64/pciqemu.c (MIT: Copyright © 2021 Plan
 * 9 Foundation, Copyright © 9front authors), which is the same forty
 * lines of idea; ../port/pci.c does the work.
 *
 * WHY THIS MACHINE HAS PCI AT ALL. Nothing on it needs a PCI device:
 * its disk, network and input are virtio-mmio. It is here because a
 * Raspberry Pi 4's USB sockets are an xHCI controller behind a PCIe
 * bridge, QEMU's model of that board has neither, and QEMU's `virt`
 * has both for the asking (-device qemu-xhci). So ../port/pci.c and the
 * xHCI driver above it can be RUN here, and only the Pi's own bridge
 * (../bcm2711/pcibcm.c) is left untried.
 *
 * WHERE THE ECAM IS. virt has two homes for it: 16MB below RAM at
 * 0x3F000000, and 256MB above it at 0x4010000000 ("highmem-ecam",
 * which a 64-bit guest gets by default since QEMU 3.0). Whichever is
 * not in use is a hole, and reading a hole is an external abort, so
 * each is asked with probe32 (../arm64/trap.c) and the one that answers
 * with a host bridge's ID is it. mmu.c maps both.
 *
 * WHERE DEVICES' REGISTERS GO. QEMU started with -kernel runs no
 * firmware, so no BAR has an address. pcibusmap() hands them out from
 * the 32-bit MMIO window at 0x10000000, which is below RAMZERO and so
 * already mapped Device. The 512GB window above RAM is not used.
 *
 * INTERRUPTS, two ways, because the machine this one stands in for has
 * only the second.
 *
 * Wires. The bridge has four level-triggered lines, shared peripheral
 * interrupts 3-6; a device in slot s using pin p (INTA = 0) is on line
 * (s + p) % 4 (hw/arm/virt.c, create_pcie). That holds for the root
 * bus only, which is where -device puts things. Lines are shared, so
 * each keeps a list and an interrupt calls every handler on it; a
 * handler must already cope with being called for nothing, as every
 * PCI driver's does.
 *
 * Messages. A device with the MSI capability is given one instead: it
 * writes an interrupt number to a register of the GIC's MSI frame
 * (GICv2m, which virt has beside a GICv2) and that shared interrupt is
 * pulsed -- so it must be made edge-triggered first. A Raspberry Pi 4's
 * bridge delivers NOTHING BUT messages (../bcm2711/pcibcm.c), so
 * ../port/pci.c's MSI code and a driver taking its interrupts that way
 * are run here or nowhere. QEMU's qemu-xhci has only MSI-X and gets a
 * wire; its nec-usb-xhci has MSI, as the Pi's VL805 does. "pcinomsi" in
 * the kernel's arguments gives everything a wire.
 *
 * DMA. A device's view of memory is the CPU's: pcibusaddr is PADDR.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/pci.h"
#include "board.h"

enum
{
	Nvec		= 8,		/* handlers per line */
	Nline		= 4,

	Hostvid		= 0x1B36,	/* Red Hat */
	Hostdid		= 0x0008,	/* QEMU's generic PCIe host bridge */
};

typedef struct Intvec Intvec;
struct Intvec
{
	Pcidev	*p;
	void	(*f)(Ureg*, void*);
	void	*a;
};

/* the GICv2m frame: ARM's Server Base System Architecture, appendix on MSI */
enum
{
	V2mtyper	= 0x008,	/* 25:16 the first interrupt, 9:0 how many */
	V2msetspi	= 0x040,	/* a device writes an interrupt number here */
};

static int msifirst, msin, msinext;	/* the frame's interrupts, and the next unused */
static int nomsi;

static volatile uchar *ecam;
static Intvec vec[Nline][Nvec];
static int lineon[Nline];
static Lock veclock;
static Pcidev *pciroot;

static void*
cfgaddr(int tbdf, int rno)
{
	if(ecam == nil)
		return nil;
	return (void*)(ecam + (BUSBNO(tbdf)<<20 | BUSDNO(tbdf)<<15 | BUSFNO(tbdf)<<12) + rno);
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

static void
pciinterrupt(Ureg *ureg, void *a)
{
	Intvec *v, *e;

	v = a;
	for(e = v + Nvec; v < e; v++)
		if(v->f != nil)
			v->f(ureg, v->a);
}

int
pciintrenable(Pcidev *p, void (*f)(Ureg*, void*), void *a, char *name)
{
	Intvec *v;
	int line, pin, i;

	/* a message if the device can send one and there is a frame to send it to */
	if(!nomsi && msin > 0 && pcicap(p, PciCapMSI) >= 0){
		ilock(&veclock);
		i = msinext < msifirst + msin ? msinext++ : -1;
		iunlock(&veclock);
		if(i >= 0 && i < Nirq){
			gicedge(i);
			intrenable(i, f, a, 0, name);
			if(pcimsienable(p, GICV2MREGS + V2msetspi, i) == 0){
				p->intl = i;
				print("pci: %T: %s interrupts by MSI, as interrupt %d\n", p->tbdf, name, i);
				return 0;
			}
			/* the handler stays on an interrupt nothing will raise */
		}
		print("pci: %T: %s: no MSI after all; trying a wire\n", p->tbdf, name);
	}

	pin = pcicfgr8(p, PciINTP);
	if(pin < 1 || pin > 4){
		print("pci: %T: %s has no interrupt pin\n", p->tbdf, name);
		return -1;
	}
	if(BUSBNO(p->tbdf) != 0){
		print("pci: %T: %s is behind a bridge, and this host routes the root bus only\n",
			p->tbdf, name);
		return -1;
	}
	line = (BUSDNO(p->tbdf) + pin - 1) % Nline;

	ilock(&veclock);
	v = nil;
	for(i = 0; i < Nvec; i++)
		if(vec[line][i].f == nil){
			v = &vec[line][i];
			break;
		}
	if(v == nil){
		iunlock(&veclock);
		print("pci: %T: %s: interrupt line %d is full\n", p->tbdf, name, line);
		return -1;
	}
	v->p = p;
	v->a = a;
	v->f = f;	/* last: pciinterrupt takes no lock */
	i = lineon[line];
	lineon[line] = 1;
	iunlock(&veclock);

	if(!i)
		intrenable(IRQpcie + line, pciinterrupt, vec[line], 0, "pci");
	p->intl = IRQpcie + line;
	print("pci: %T: %s interrupts by wire, INT%c, as interrupt %d\n", p->tbdf, name, 'A'+pin-1, p->intl);
	return 0;
}

u64int
pcibusaddr(void *va)
{
	return PADDR(va);
}

/*
 * Memory a device can reach is all of it, so this is malloc with an
 * alignment: over-allocate, and keep what malloc gave just below what
 * the caller gets.
 */
void*
pcidmaalloc(ulong size, int align)
{
	uchar *m, *p;

	if(align < (int)sizeof(void*))
		align = sizeof(void*);
	m = malloc(size + align + sizeof(void*));
	if(m == nil)
		return nil;
	p = (uchar*)ROUND((uintptr)m + sizeof(void*), (uintptr)align);
	((void**)p)[-1] = m;
	return p;
}

void
pcidmafree(void *p, ulong size)
{
	USED(size);
	if(p != nil)
		free(((void**)p)[-1]);
}

/*
 * Every buffer is reachable here -- which would leave a driver's bounce
 * path, the one a Raspberry Pi 4 cannot do without, never run by
 * anything. "pcibounce" in the kernel's arguments makes this say no to
 * everything, and the harness boots that way once.
 */
static int bounceall;

int
pcidmaok(void *va, ulong len)
{
	USED(va);
	USED(len);
	return !bounceall;
}

/*
 * Called from boarddevprobe: board init, in kmain, no scheduler. A
 * machine started without PCI devices still has the bridge; what it
 * says then is one line.
 */
void
pciecamlink(void)
{
	static uintptr where[] = { PCIECAMHIGH, PCIECAMLOW };
	u32int id;
	uvlong base;
	ulong ioa;
	char *a;
	int i;

	for(a = boardcmdline(); *a != 0; a++)
		if((a == boardcmdline() || a[-1] == ' ') && strncmp(a, "pcibounce", 9) == 0){
			bounceall = 1;
			print("pci: pcibounce: every buffer a PCI driver is handed will be refused and bounced\n");
		}else if((a == boardcmdline() || a[-1] == ' ') && strncmp(a, "pcinomsi", 8) == 0)
			nomsi = 1;

	for(i = 0; i < nelem(where); i++){
		if(probe32(where[i], &id) < 0)
			continue;
		if(id == (Hostdid<<16 | Hostvid)){
			ecam = (uchar*)where[i];
			break;
		}
	}
	if(ecam == nil){
		print("pci: no ECAM host bridge at %#p or %#p\n", where[0], where[1]);
		return;
	}

	fmtinstall('T', tbdffmt);
	pcimaxdno = 31;
	pciscan(0, &pciroot, nil);
	if(pciroot == nil){
		print("pci: ECAM at %#p: nothing on the bus\n", ecam);
		return;
	}

	ioa = 0;
	base = PCIMMIO;
	pcibusmap(pciroot, &base, &ioa, 1);
	if(base > PCIMMIO + PCIMMIOSIZE)
		print("pci: DEVICES WANT %#llux OF A %#ux WINDOW -- some have addresses that go nowhere\n",
			base - PCIMMIO, PCIMMIOSIZE);

	print("pci: ECAM at %#p, windows from %#ux\n", ecam, PCIMMIO);
	pcihinv(pciroot);

	/* the MSI frame: there with a GICv2 unless QEMU was told msi=off */
	if(probe32(GICV2MREGS + V2mtyper, &id) == 0 && (id & 0x3FF) != 0){
		msifirst = (id >> 16) & 0x3FF;
		msin = id & 0x3FF;
		msinext = msifirst;
		print("pci: MSI frame at %#ux: interrupts %d-%d%s\n", GICV2MREGS,
			msifirst, msifirst+msin-1, nomsi ? " (pcinomsi: not used)" : "");
	}else
		print("pci: no MSI frame; every device gets a wire\n");
}
