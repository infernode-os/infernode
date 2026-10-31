/*
 * Memory layout and sizes for a Microchip PolarFire SoC (BeagleV-Fire, Icicle Kit).
 *
 * DDR is at 0x80000000 (the cached low window). OpenSBI -- the Hart
 * Software Services' on the board, QEMU's -bios on the Icicle Kit model
 * -- occupies the first 2MB of it and
 * starts the kernel at 0x80200000, which is where kernel.ld links it.
 * There is no paging (../riscv64/mmu.c), so kernel addresses are
 * physical and KADDR/PADDR are casts.
 */

#define	BY2WD		8			/* bytes per word */
#define	BY2V		8			/* bytes per vlong */
#define	BY2PG		4096			/* bytes per page */
#define	WD2PG		(BY2PG/BY2WD)		/* words per page */
#define	PGSHIFT		12			/* log2(BY2PG) */
#define	PGROUND(s)	(((s)+(BY2PG-1))&~(BY2PG-1))
#define	ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))

#define	HZ		1000			/* clock ticks per second */
#define	MS2HZ		(1000/HZ)		/* milliseconds per tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

#define	MAXMACH		4			/* the four U54 application harts */
#define	CACHELINESZ	64
#define	KSTACK		(16*1024)		/* kernel stack per process */

#define	KZERO		0
#define	KADDR(a)	((void*)(uintptr)(a))
#define	PADDR(a)	((uintptr)(a))

#define	RAMZERO		0x80000000
#define	KTZERO		(RAMZERO+0x200000)	/* where OpenSBI enters us */
