/*
 * MMU and page tables for the virt machine.
 *
 * Identity mapping (VA == PA), as on BCM2837 and for the same reason:
 * there is no user space yet, so a translation that changed addresses
 * would buy nothing and cost a debugging dimension. What it buys
 * immediately is memory ATTRIBUTES -- with the MMU off, ARMv8 treats
 * every access as Device-nGnRnE, where unaligned access is forbidden
 * outright and nothing is cached.
 *
 * The map is the inverse of the Pi's, which is why this is a separate
 * file rather than a shared one with a different constant:
 *
 *   [0, 1GB)          Device-nGnRnE.  Flash, GIC, PL011, virtio-mmio,
 *                     the PCIe windows -- the whole peripheral region.
 *   [1GB, ramtop)     Normal, write-back cacheable, inner shareable.
 *                     RAM. Where the kernel is running from.
 *   [ramtop, 4GB)     Device-nGnRnE.  Unpopulated; mapped rather than
 *                     left as a translation fault so that a stray
 *                     access reports as a data abort with a sensible
 *                     FAR rather than as a table walk into nothing.
 *
 * On BCM2837 RAM starts at 0 and peripherals sit above it. Here it is
 * the other way round, so a single "below ramtop is RAM" test -- which
 * is what the Pi's mmu.c uses -- would map the entire peripheral region
 * cacheable. That fails in the least helpful way available: the console
 * works (the first writes sit in a dirty line and drain eventually),
 * the GIC does not, and the kernel hangs with no output about why.
 *
 * Granule is 4KB with 2MB block descriptors at level 2, so four level-2
 * tables cover the low 4GB in 20KB of .bss rather than a forest of leaf
 * pages.
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
	 * entries of 2MB. Four level-2 tables cover the low 4GB, which
	 * is as much as IPS=0 (a 32-bit physical address size) permits
	 * anyway -- so -m up to 3GB works and anything larger is
	 * clamped rather than silently half-mapped.
	 */
	Nl2tab		= 4,
	Ntabent		= 512,

	L2blocksize	= 2*1024*1024,
	Mapped		= (uvlong)Nl2tab * Ntabent * L2blocksize,

	/* descriptor types */
	Dtable		= 3,		/* points at a next-level table */
	Dblock		= 1,		/* a block of memory, here 2MB */

	/* lower attributes */
	Attridx0	= 0<<2,		/* MAIR index 0: Normal WB */
	Attridx1	= 1<<2,		/* MAIR index 1: Device-nGnRnE */
	Apkrw		= 0<<6,		/* EL1 read/write, EL0 none */
	Shnone		= 0<<8,
	Shinner		= 3<<8,
	Af		= 1<<10,	/* access flag: MUST be set, or every
					 * access takes an access-flag fault */

	/* SCTLR_EL1 */
	Sctlrm		= 1<<0,		/* MMU enable */
	Sctlrc		= 1<<2,		/* data cache enable */
	Sctlri		= 1<<12,	/* instruction cache enable */

	/*
	 * If the device tree cannot be read, assume the smallest thing
	 * QEMU will give us. 128MB is virt's default when -m is not
	 * passed, so a wrong guess here under-uses memory rather than
	 * handing xalloc pages that do not exist.
	 */
	Deframsize	= 128*1024*1024,
};

/* upper attributes -- not enum members, as bits 53/54 exceed int */
#define Pxn		(1ULL<<53)	/* privileged execute never */
#define Uxn		(1ULL<<54)	/* unprivileged execute never */

/* MAIR: attr0 = Normal WB read/write-allocate, attr1 = Device-nGnRnE */
#define Mairval		(0x00ULL<<8 | 0xFFULL)

/*
 * TCR: T0SZ=25 for a 39-bit VA, TTBR0 walks inner-shareable and
 * write-back cacheable, 4KB granule. TTBR1 walks are disabled: with no
 * high half mapped, a TTBR1 walk could only ever be a bug, and EPD1
 * turns that bug into a clean translation fault.
 */
#define Tcrval		(25ULL		/* T0SZ */		\
			| 25ULL<<16	/* T1SZ */		\
			| 1ULL<<8	/* IRGN0: WB WA */	\
			| 1ULL<<10	/* ORGN0: WB WA */	\
			| 3ULL<<12	/* SH0: inner */	\
			| 0ULL<<14	/* TG0: 4KB */		\
			| 1ULL<<23	/* EPD1 */		\
			| 0ULL<<32)	/* IPS: 32-bit PA */

static u64int l1tab[Ntabent] __attribute__((aligned(4096)));
static u64int l2tab[Nl2tab][Ntabent] __attribute__((aligned(4096)));

static uintptr rambase = PHYSMEM;
static uintptr ramtop;
static int ramfromdtb;

uintptr
mmurambase(void)
{
	return rambase;
}

int
mmuramknown(void)
{
	return ramfromdtb;
}

/*
 * How much RAM is there?
 *
 * -m is a command-line argument, so unlike a board this genuinely
 * cannot be known at compile time. QEMU describes it in the device
 * tree it passes in x0, which is the same way a Linux kernel finds out.
 */
static void
findram(void)
{
	uintptr base, size;

	if(fdtmemory(&base, &size) == 0 && size != 0){
		rambase = base;
		ramtop = base + size;
		ramfromdtb = 1;
	}else{
		rambase = PHYSMEM;
		ramtop = PHYSMEM + Deframsize;
		ramfromdtb = 0;
	}

	if(ramtop > (uintptr)Mapped)
		ramtop = (uintptr)Mapped;
}

void
mmuinit(void)
{
	uintptr pa;
	u64int desc;
	int i, j;

	findram();

	/* level 1: one entry per level-2 table, each covering 1GB */
	for(i = 0; i < Ntabent; i++)
		l1tab[i] = 0;
	for(i = 0; i < Nl2tab; i++)
		l1tab[i] = (u64int)(uintptr)&l2tab[i][0] | Dtable;

	/* level 2: 2MB blocks, attributes chosen by where they land */
	for(i = 0; i < Nl2tab; i++){
		for(j = 0; j < Ntabent; j++){
			pa = (uintptr)((i * Ntabent + j) * (uvlong)L2blocksize);

			if(pa >= rambase && pa < ramtop)
				desc = Dblock | Attridx0 | Apkrw | Shinner | Af;
			else
				desc = Dblock | Attridx1 | Apkrw | Shnone | Af |
					Pxn | Uxn;

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
 * Turn it on. Order matters and the barriers are not optional: the
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
