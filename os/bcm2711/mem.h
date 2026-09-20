/*
 * Memory layout and machine constants for BCM2711 (Raspberry Pi 4).
 *
 * The same as ../bcm2837/mem.h, whose comments give the reasons, but for
 * MAPGB and SDCARD_ARASAN at the end.
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
 * Clock rate. clock.c programs the timer comparator from this same
 * number rather than a second copy of it: os/port converts
 * milliseconds to ticks with MS2TK, so a mismatch between the two
 * would make every sleep and timeout wrong by that ratio without
 * anything looking broken.
 *
 * A thousand, not the hundred every other Plan 9 ARM port uses, and the
 * reason is measured rather than aesthetic.
 *
 * MS2TK divides by 1000/HZ, so at a hundred ticks a second MS2TK(1) is
 * ZERO and a one-millisecond sleep means "until the next tick" -- up to
 * ten milliseconds. The USB driver retries a NAKed bulk IN on exactly
 * such a sleep, which is how the ethernet receive path came to poll its
 * endpoint about fifty times a second: the driver's own counters showed
 * 10219 empty reads costing 21.4ms each, and a round trip through the
 * board taking 44ms on a wire whose transit time is microseconds. A TCP
 * window divided by that round trip was the whole of this port's
 * network throughput.
 *
 * Nothing here counts wall-clock time in ticks without scaling, so the
 * cost is the extra timer interrupts, which a 1.2GHz Cortex-A53 does
 * not notice, and the gain is that a millisecond means a millisecond.
 */
#define	HZ		1000			/* clock ticks per second */
#define	MS2HZ		(1000/HZ)		/* milliseconds per tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

#define	MAXMACH		4			/* four Cortex-A72 cores */

/*
 * How much of the address space ../bcm/mmu.c maps, in gigabytes. Four:
 * the peripheral window is at 0xFE000000, the GIC just above it.
 *
 * RAM above the first gigabyte IS used, up to RAMLIMIT, and that is
 * safe only because of ../bcm/dmamem.c: several of this SoC's DMA
 * masters reach only the first gigabyte (DMATOP), QEMU does not model
 * that, and the drivers in ../bcm were written where every address was
 * reachable. Read that file before changing either number.
 *
 * RAMLIMIT is where the peripheral window begins. An 8GB board has
 * memory above 4GB as well; using it needs more than 32 bits of
 * physical address in ../bcm/mmu.c and has not been attempted.
 */
#define	MAPGB		4
#define	DMATOP		0x40000000UL
#define	RAMLIMIT	0xFC000000UL

/*
 * The card is on an SDHCI controller (EMMC2; see io.h), not on SDHOST.
 * ../bcm/sdmmc.c picks between the two when it is compiled.
 */
#define	SDCARD_ARASAN	1

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
