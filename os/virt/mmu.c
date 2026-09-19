/*
 * MMU and page tables.
 *
 * A flat identity map, for os/bcm2837/mmu.c's reasons: no user space,
 * so a translation that moved addresses would buy nothing; what the MMU
 * buys is memory ATTRIBUTES, and with it off every access is
 * Device-nGnRnE -- uncached, and faulting on anything unaligned.
 *
 * Two regions, as on the board, and in the opposite order:
 *
 *   [0, 1GB)             Device-nGnRnE. Everything that is not memory:
 *                        flash, the GIC, the PL011, fw_cfg, the virtio
 *                        transports, PCIe windows.
 *
 *   [1GB, ramtop)        Normal, write-back cacheable. RAM starts at
 *                        RAMZERO and its size comes from the device
 *                        tree, because it is whatever -m said.
 *
 *   [ramtop, 8GB)        not mapped. An access is a translation fault
 *                        with the address in FAR, which is a better
 *                        report than whatever reading nothing returns.
 *
 * THE ORDER IS THE TRAP. The board's rule is "below ramtop is Normal,
 * above it is Device", and on the board that is right because its
 * peripherals sit above its memory. Carried here it maps the GIC and
 * the UART as cacheable memory. The UART keeps working -- QEMU does
 * not model caches, and a write is a write -- so the console says all
 * is well while the interrupt controller, mapped with attributes that
 * permit speculative reads and write merging, is whatever it happens
 * to be. A first virt port lost an afternoon to exactly that. The test
 * here is "inside [RAMZERO, ramtop)", stated as that and nothing
 * cleverer.
 *
 * The framebuffer is not a special case here. On the board it lives in
 * the VideoCore's memory, which the GPU reads without seeing the ARM's
 * caches, so it is remapped Normal NON-cacheable (mmunormalnc). Here a
 * framebuffer is ordinary guest RAM that QEMU reads from the host side,
 * coherent by construction; mmunormalnc is kept, because screen code
 * shared with the board calls it, and does nothing.
 *
 * Granule is 4KB with 2MB block descriptors at level 2, as on the
 * board; eight level-2 tables cover 8GB, which is 1GB of peripherals
 * and up to 7GB of RAM.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

enum
{
	/*
	 * 39-bit VA: level 1 has 512 entries of 1GB, level 2 has 512
	 * entries of 2MB.  Eight level-2 tables cover the low 8GB.
	 */
	Nl2tab		= 8,
	Ntabent		= 512,

	L2blocksize	= 2*1024*1024,

	/* descriptor types */
	Dtable		= 3,		/* points at a next-level table */
	Dblock		= 1,		/* a block of memory, here 2MB */

	/* lower attributes */
	Attridx0	= 0<<2,		/* MAIR index 0: Normal WB */
	Attridx1	= 1<<2,		/* MAIR index 1: Device-nGnRnE */
	Attridx2	= 2<<2,		/* MAIR index 2: Normal, non-cacheable */
	Apkrw		= 0<<6,		/* EL1 read/write, EL0 none */
	Shnone		= 0<<8,
	Shinner		= 3<<8,
	Af		= 1<<10,	/* access flag: MUST be set, or every
					 * access takes an access-flag fault */

	/* SCTLR_EL1 */
	Sctlrm		= 1<<0,		/* MMU enable */
	Sctlrc		= 1<<2,		/* data cache enable */
	Sctlri		= 1<<12,	/* instruction cache enable */
};

#define Mapped		((uvlong)Nl2tab * Ntabent * L2blocksize)

/*
 * If the device tree will not say how much memory there is: QEMU's own
 * default for -m, which is the least it can be unless someone asked
 * for less -- and someone who asked for less gets a translation fault
 * at the top of xalloc's bank, which names the problem.
 */
#define Deframsize	(128ULL*1024*1024)


/*
 * These are #defines rather than enum members because a C enum constant
 * must be representable as an int, and these are not: the execute-never
 * bits live at 53 and 54, and TCR/MAIR are 64-bit register values.
 */

/* upper attributes */
#define Pxn		(1ULL<<53)	/* privileged execute never */
#define Uxn		(1ULL<<54)	/* unprivileged execute never */

/*
 * MAIR: attr0 = 0xFF (Normal, inner and outer write-back, read and
 * write allocate), attr1 = 0x00 (Device-nGnRnE), attr2 = 0x44 (Normal,
 * inner and outer NON-cacheable).
 *
 * attr2 exists for the framebuffer. Device-nGnRnE is the safe default
 * for anything above ramtop because it makes no assumptions, but it
 * also forbids write combining and reordering, so every store is its
 * own bus transaction. A screen is not a control register: it wants
 * bulk stores, and mapping 1.5MB of it as Device made a console write
 * take the better part of two seconds.
 *
 * Normal non-cacheable is the right attribute. The GPU does not snoop
 * the ARM caches, so caching it would need maintenance on every draw --
 * but non-cacheable Normal needs none, while still allowing the wide,
 * combined accesses that make a memmove of a screen reasonable.
 */
#define Mairval		(0x44ULL<<16 | 0x00ULL<<8 | 0xFFULL)

/*
 * TCR: T0SZ=25 for a 39-bit VA, TTBR0 walks inner-shareable and
 * write-back cacheable, 4KB granule.  TTBR1 walks are disabled because
 * only TTBR0 is used while the map is a flat identity -- with no high
 * half mapped, a TTBR1 walk could only ever be a bug, and EPD1 turns
 * that bug into a clean translation fault.
 */
#define Tcrval		(25ULL		/* T0SZ */		\
			| 25ULL<<16	/* T1SZ */		\
			| 1ULL<<8	/* IRGN0: WB WA */	\
			| 1ULL<<10	/* ORGN0: WB WA */	\
			| 3ULL<<12	/* SH0: inner */	\
			| 0ULL<<14	/* TG0: 4KB */		\
			| 1ULL<<23	/* EPD1 */		\
			| 2ULL<<32)	/* IPS: 40-bit PA; RAM can pass 4GB */

/*
 * Page tables live in .bss and are 4KB aligned as the architecture
 * requires.  These are written while the MMU is still off, so every
 * store lands on Device memory -- but the tables are 4096-aligned and
 * written as sequential 8-byte entries, so any store-pair the compiler
 * emits is naturally aligned and cannot fault the way the mailbox
 * buffer did.
 */
static u64int l1tab[Ntabent] __attribute__((aligned(4096)));
static u64int l2tab[Nl2tab][Ntabent] __attribute__((aligned(4096)));

static uintptr ramtop;

/*
 * Where does memory end? Ask the device tree: it is the only thing
 * that knows what -m was.
 */
static uintptr
findramtop(void)
{
	uintptr base, size;

	if(fdtmemory(&base, &size) == 0 && base == RAMZERO && size != 0){
		if(base + size > Mapped)
			return (uintptr)Mapped;
		return base + size;
	}
	uartputstr("mmu:  no usable /memory in the device tree; assuming 128MB\n");
	return RAMZERO + (uintptr)Deframsize;
}

void
mmuinit(void)
{
	uintptr pa;
	u64int desc;
	int i, j;

	ramtop = findramtop();

	/* level 1: one entry per level-2 table, each covering 1GB */
	for(i = 0; i < Ntabent; i++)
		l1tab[i] = 0;
	for(i = 0; i < Nl2tab; i++)
		l1tab[i] = (u64int)(uintptr)&l2tab[i][0] | Dtable;

	/* level 2: 2MB blocks, attributes chosen by where they land */
	for(i = 0; i < Nl2tab; i++){
		for(j = 0; j < Ntabent; j++){
			pa = (uintptr)((i * Ntabent + j) * (uvlong)L2blocksize);

			if(pa >= RAMZERO && pa < ramtop)
				desc = Dblock | Attridx0 | Apkrw | Shinner | Af;
			else if(pa < RAMZERO)
				desc = Dblock | Attridx1 | Apkrw | Shnone | Af |
					Pxn | Uxn;
			else{
				l2tab[i][j] = 0;	/* invalid: fault */
				continue;
			}

			l2tab[i][j] = (u64int)pa | desc;
		}
	}

	mmuenable();
}

uintptr
mmuramtop(void)
{
	return ramtop;
}

u64int
mmutcr(void)
{
	return Tcrval;
}

u64int
mmumair(void)
{
	return Mairval;
}

uintptr
mmul1(void)
{
	return (uintptr)&l1tab[0];
}

uintptr
mmumapped(void)
{
	return (uintptr)Mapped;
}

/*
 * Turn it on.  Order matters and the barriers are not optional: the
 * table writes must be visible to the table walker before TTBR0 is
 * loaded, and the system registers must have taken effect before the
 * first translated fetch.
 */
void
mmuenable(void)
{
	u64int sctlr;

	__asm__ volatile("dsb sy" ::: "memory");

	__asm__ volatile("msr mair_el1, %0" :: "r"(Mairval));
	__asm__ volatile("msr tcr_el1, %0" :: "r"(Tcrval));
	__asm__ volatile("msr ttbr0_el1, %0" :: "r"((u64int)(uintptr)&l1tab[0]));
	__asm__ volatile("isb");

	__asm__ volatile("tlbi vmalle1");
	__asm__ volatile("ic iallu");
	__asm__ volatile("dsb sy" ::: "memory");
	__asm__ volatile("isb");

	__asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
	sctlr |= Sctlrm | Sctlrc | Sctlri;
	__asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr));
	__asm__ volatile("isb");
}

int
mmuon(void)
{
	u64int sctlr;

	__asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
	return (sctlr & Sctlrm) != 0;
}

int
mmucaches(void)
{
	u64int sctlr;

	__asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
	return (sctlr & (Sctlrc|Sctlri)) == (Sctlrc|Sctlri);
}

/*
 * The board remaps its framebuffer Normal non-cacheable with this. A
 * framebuffer here is guest RAM and needs nothing; see the top of the
 * file.
 */
void
mmunormalnc(uintptr base, usize len)
{
	USED(base);
	USED(len);
}
