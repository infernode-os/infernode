/*
 * Memory layout and machine constants for BCM2837.
 *
 * os/port expects each platform to supply this. The values that matter
 * most are the word sizes, because upstream's allocators do their
 * rounding in terms of them.
 */

/*
 * BY2WD is 8 here, not 4.
 *
 * Every existing upstream os/ port sets this to 4, because every one of
 * them is 32-bit. It is the size of a machine word, used by xalloc.c and
 * allocb.c to round allocations and reserve header slots -- so getting
 * it wrong does not fail loudly, it silently misaligns every allocation
 * the kernel makes.
 *
 * BY2V (the "vlong" alignment) stays 8: it was already 8 on 32-bit
 * machines because vlong was always 64 bits. On AArch64 the two
 * coincide, which is why upstream code that rounds to BY2V happens to
 * be correct here without change.
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

#define	MAXMACH		4			/* four Cortex-A53 cores */

/*
 * Cortex-A53 L1 data cache line. Upstream's bcm port says 32, which is
 * the ARM11 in a Pi 1; getting this too LARGE skips lines during cache
 * maintenance and corrupts DMA under load, so it is worth stating
 * per-SoC rather than inheriting.
 */
#define	CACHELINESZ	64

#define	KSTACK		(16*1024)		/* kernel stack per process */

/*
 * Virtual/physical translation.
 *
 * The map is a flat identity (see mmu.c), so these are the identity.
 * They exist as macros rather than being elided because upstream code
 * calls them constantly, and keeping the call sites intact means those
 * files stay diff-able against their originals -- and means introducing
 * a real offset later touches only this header.
 */
#define	KZERO		0
#define	KADDR(a)	((void*)(uintptr)(a))
#define	PADDR(a)	((uintptr)(a))

/*
 * Where the kernel image sits. The AArch64 boot protocol loads
 * kernel8.img at 0x80000; the stack grows down from there into the
 * memory below, which the firmware leaves free.
 */
#define	KTZERO		0x80000
