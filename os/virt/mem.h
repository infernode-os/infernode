/*
 * Memory layout and machine constants for QEMU's `virt` machine.
 *
 * The word sizes, HZ and the cache line are os/bcm2837/mem.h's, for
 * os/bcm2837/mem.h's reasons -- read them there. What differs is where
 * things are: on virt the peripherals sit BELOW memory, RAM starts at
 * 1GB, and how much of it there is depends on -m.
 */
#define	BY2WD		8			/* bytes per word */
#define	BY2V		8			/* bytes per vlong */
#define	BY2PG		4096			/* bytes per page */
#define	WD2PG		(BY2PG/BY2WD)		/* words per page */
#define	PGSHIFT		12			/* log2(BY2PG) */
#define	PGROUND(s)	(((s)+(BY2PG-1))&~(BY2PG-1))

/* round s up to a multiple of sz, which must be a power of two */
#define	ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))

#define	HZ		1000			/* clock ticks per second */
#define	MS2HZ		(1000/HZ)		/* milliseconds per tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

/*
 * The same four as the board, so the two kernels schedule alike and a
 * bug that needs four cores to show has them. Run with -smp 4; with
 * fewer, the cores that are not there do not answer and the kernel
 * says so.
 */
#define	MAXMACH		4

#define	CACHELINESZ	64

#define	KSTACK		(16*1024)		/* kernel stack per process */

/* a flat identity map, as on the board; see mmu.c */
#define	KZERO		0
#define	KADDR(a)	((void*)(uintptr)(a))
#define	PADDR(a)	((uintptr)(a))

/*
 * Where memory starts, and where the kernel sits in it.
 *
 * QEMU loads a flat image the way the arm64 Linux boot protocol says
 * to: 0x80000 above the base of RAM, with the device tree's address in
 * x0. The half megabyte below the image is free, and the boot stack
 * grows down into it exactly as it does on the board.
 */
#define	RAMZERO		0x40000000
#define	KTZERO		(RAMZERO+0x80000)
