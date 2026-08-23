/*
 * MMU and page tables.
 *
 * Identity mapping (VA == PA) for now: there is no user space, no
 * processes and no kernel/user split yet, so a translation that changes
 * addresses would buy nothing and cost a debugging dimension.  What it
 * DOES buy, immediately, is memory attributes.
 *
 * With the MMU off, ARMv8 treats every access as Device-nGnRnE.  That
 * has two consequences that have already cost time here: unaligned
 * access is forbidden outright (which is how a compiler-merged 64-bit
 * store at a 4-byte-aligned offset took an alignment fault in the
 * mailbox code), and every access goes to memory with no cache, which is
 * slow enough to matter once anything touches a framebuffer.
 *
 * So the map has exactly two regions:
 *
 *   [0, ramtop)          Normal, write-back cacheable, inner shareable.
 *                        Kernel, stack, and anything the ARM alone owns.
 *
 *   [ramtop, 2GB)        Device-nGnRnE.  Peripherals AND the VideoCore
 *                        memory split, which is where the firmware puts
 *                        the framebuffer.
 *
 * That second point is the subtle one.  The framebuffer is shared with
 * the GPU, and the GPU does not snoop the ARM's caches.  Mapping it
 * cacheable would mean ARM writes sit in a dirty cache line while the
 * display shows stale pixels, and every write would then need explicit
 * cache maintenance.  Mapping it Device sidesteps the whole problem, and
 * ramtop comes from asking the firmware where the split actually is
 * rather than from a constant that would rot.
 *
 * Granule is 4KB with 2MB block descriptors at level 2, so a region is
 * described by three tables totalling 12KB rather than by a forest of
 * leaf pages.
 */

#include "u.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

enum
{
	/*
	 * 39-bit VA: level 1 has 512 entries of 1GB, level 2 has 512
	 * entries of 2MB.  Two level-2 tables cover the low 2GB, which
	 * is everything on this SoC -- RAM tops out at 1GB and the ARM
	 * local peripherals sit just above it at 0x40000000.
	 */
	Nl2tab		= 2,
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

	/* fallback if the firmware will not say where the split is */
	Deframtop	= 0x3C000000,
};

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
 * write allocate), attr1 = 0x00 (Device-nGnRnE).
 */
#define Mairval		(0x00ULL<<8 | 0xFFULL)

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
			| 0ULL<<32)	/* IPS: 32-bit PA */

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
 * Where does ARM-visible memory end?  Above this the VideoCore owns the
 * memory, and the framebuffer is allocated up there.  Ask the firmware
 * rather than assuming: the split is configurable in config.txt.
 */
static uintptr
findramtop(void)
{
	u32int mem[2];

	mem[0] = 0;
	mem[1] = 0;
	if(mboxprop(Taggetarmmem, mem, 0, 2) == 0 && mem[1] != 0)
		return (uintptr)mem[0] + (uintptr)mem[1];

	return Deframtop;
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

			if(pa < ramtop)
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
