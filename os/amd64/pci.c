/*
 * os/amd64/pci.c -- PCI configuration space, mechanism #1.
 *
 * The kernel has no PCI bus abstraction and needs almost none: one
 * configuration address port and one data port will do for the devices
 * a Multiboot loader puts in front of us.  QEMU's i440fx and 9vm both
 * implement the legacy 0xCF8/0xCFC pair, so that is the mechanism used;
 * ECAM (memory-mapped config space) would need an ACPI MCFG table this
 * kernel does not read.
 *
 * A config address is 0x80000000 | bus<<16 | dev<<11 | fn<<8 | reg,
 * where reg is aligned to four bytes; the data port returns that word
 * and the caller takes the 16- or 8-bit piece it wants.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

#define PCICFG		0xCF8
#define PCIDATA		0xCFC

uint32_t
pcicfgr32(int bus, int dev, int fn, int reg)
{
	uint32_t a;

	a = 0x80000000u | (uint32_t)(bus & 0xFF) << 16 |
	    (uint32_t)(dev & 0x1F) << 11 | (uint32_t)(fn & 7) << 8 |
	    (uint32_t)(reg & 0xFC);
	/* the data port is one 32-bit register at 0xCFC; only the
	 * address register carries the alignment */
	outl(PCICFG, a);
	return inl(PCIDATA);
}

void
pcicfgw32(int bus, int dev, int fn, int reg, uint32_t v)
{
	uint32_t a;

	a = 0x80000000u | (uint32_t)(bus & 0xFF) << 16 |
	    (uint32_t)(dev & 0x1F) << 11 | (uint32_t)(fn & 7) << 8 |
	    (uint32_t)(reg & 0xFC);
	outl(PCICFG, a);
	outl(PCIDATA, v);
}

uint16_t
pcicfgr16(int bus, int dev, int fn, int reg)
{
	return pcicfgr32(bus, dev, fn, reg) >> ((reg & 2) * 8);
}

uint8_t
pcicfgr8(int bus, int dev, int fn, int reg)
{
	return pcicfgr32(bus, dev, fn, reg) >> ((reg & 3) * 8);
}

void
pciwrite8(int bus, int dev, int fn, int reg, uint8_t v)
{
	uint32_t w;
	int sh;

	sh = (reg & 3) * 8;
	w = pcicfgr32(bus, dev, fn, reg);
	w = (w & ~(0xFFu << sh)) | (uint32_t)v << sh;
	pcicfgw32(bus, dev, fn, reg, w);
}

void
pciwrite16(int bus, int dev, int fn, int reg, uint16_t v)
{
	uint32_t w;
	int sh;

	sh = (reg & 2) * 8;
	w = pcicfgr32(bus, dev, fn, reg);
	w = (w & ~(0xFFFFu << sh)) | (uint32_t)v << sh;
	pcicfgw32(bus, dev, fn, reg, w);
}

/*
 * Map a device's MMIO window into the identity map.
 *
 * boot.S maps the first GiB and the 0xF8000000 display window; a PCI
 * BAR lives somewhere else in the fourth GiB (0xFEB01000 on 9vm, and
 * anywhere in 0xFE... on QEMU).  The page tables are the boot ones --
 * one PDPT entry for 0xC0000000..0xFFFFFFFF pointing at bootpd2, whose
 * entries are 2 MiB pages -- so mapping a window is filling in the
 * entry that covers it, uncached (PCD), and invalidating the TLB for
 * the page.  This is enough while the kernel has no address spaces of
 * its own; a real mapper arrives with them.
 */
extern uint64_t	bootpd2[512];

void*
mmiomap(uint64_t pa, uint64_t len)
{
	uint64_t start, end, p, *pde;
	uintptr_t cr3;

	start = pa & ~0x1FFFFFULL;
	end = (pa + len + 0x1FFFFFULL) & ~0x1FFFFFULL;
	if(start < 0xC0000000ULL || end > 0x100000000ULL){
		/* not in the PDPT entry boot.S provides */
		return nil;
	}
	/*
	 * The display window is the one range in that gigabyte boot.S
	 * maps for a purpose: 0xF8000000..0xFBFFFFFF.  A BAR there would
	 * silently replace it, so refuse rather than map over it.
	 */
	if(start < 0xFC000000ULL && end > 0xF8000000ULL)
		return nil;
	for(p = start; p < end; p += 0x200000ULL){
		pde = &bootpd2[(p >> 21) & 511];
		*pde = p | 0x83 | 0x10;	/* P | RW | PS | PCD */
		__asm__ volatile("invlpg (%0)" : : "r"((void*)(uintptr_t)p) : "memory");
	}
	__asm__ volatile("movq %%cr3, %0" : "=r"(cr3));
	__asm__ volatile("movq %0, %%cr3" : : "r"(cr3) : "memory");
	return (void*)(uintptr_t)pa;
}
