/*
 * Memory layout and machine constants for the QEMU virt machine.
 *
 * Deliberately kept diff-able against os/bcm2837/mem.h: everything here
 * except KTZERO is identical, and it is worth being able to see that at
 * a glance rather than having to read both files to find out.
 */

/*
 * BY2WD is 8, not 4.
 *
 * Every upstream os/ port sets this to 4 because every one of them is
 * 32-bit. It is the size of a machine word, used by xalloc.c and
 * allocb.c to round allocations and reserve header slots -- so getting
 * it wrong does not fail loudly, it silently misaligns every allocation
 * the kernel makes.
 */
#define	BY2WD		8			/* bytes per word */
#define	BY2V		8			/* bytes per vlong */
#define	BY2PG		4096			/* bytes per page */
#define	WD2PG		(BY2PG/BY2WD)		/* words per page */
#define	PGSHIFT		12			/* log2(BY2PG) */
#define	PGROUND(s)	(((s)+(BY2PG-1))&~(BY2PG-1))

/* round s up to a multiple of sz, which must be a power of two */
#define	ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))

/*
 * Clock rate. Must agree with the Hz enum in clock.c, which is what
 * actually programs the timer comparator -- os/port converts
 * milliseconds to ticks with MS2TK, so a mismatch makes every sleep and
 * timeout wrong by that ratio without anything looking broken.
 */
#define	HZ		100			/* clock ticks per second */
#define	MS2HZ		(1000/HZ)		/* milliseconds per tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

#define	MAXMACH		4			/* -smp 4; only core 0 runs so far */

#define	KSTACK		(16*1024)		/* kernel stack per process */

/*
 * Virtual/physical translation. The map is a flat identity (see mmu.c),
 * so these are the identity -- kept as macros because upstream code
 * calls them constantly and keeping the call sites intact means those
 * files stay diff-able against their originals.
 */
#define	KZERO		0
#define	KADDR(a)	((void*)(uintptr)(a))
#define	PADDR(a)	((uintptr)(a))

/*
 * Where the kernel image sits.
 *
 * QEMU loads a raw -kernel image for AArch64 at the machine's RAM base
 * plus 0x80000, and starts the CPU there directly -- there is no
 * firmware shim, unlike raspi3b which enters at 0x0 and branches. RAM
 * base on virt is 0x40000000, so the load address is 0x40080000 and the
 * 512KB below it is where the boot stack grows down into.
 */
#define	KTZERO		0x40080000
