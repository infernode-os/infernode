/*
 * Memory layout and machine constants for BCM2712 (Raspberry Pi 5).
 *
 * ../bcm2711/mem.h, whose comments and ../bcm2837/mem.h's give the
 * reasons, but for the device windows and what the secure firmware owns.
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

#define	MAXMACH		4			/* four Cortex-A76 cores */

/*
 * The low 4GB is memory (RAMLIMIT is below the VideoCore's block, at
 * 0xFDB00000 on the 8GB board); the devices are far above it, each of
 * these a Device gigabyte at level 1 of the tables (../bcm/mmu.c):
 * 0x10_0000_0000 the SoC's newer blocks, 0x10_4000_0000 the old
 * peripheral window with the GIC at its top, and 0x1C_0000_0000 RP1,
 * where the firmware leaves it with pciex4_reset=0. 2 in MMUIPS is the
 * 40 bits this CPU reports.
 *
 * Memory above 4GB is not used yet.
 */
#define	MAPGB		4
#define	DMATOP		0x40000000UL
#define	IOWINS		{ 0x1000000000ULL, 0x1040000000ULL, 0x1B80000000ULL, 0x1C00000000ULL }
#define	MMUIPS		2
#define	RAMLIMIT	0xFC000000UL

/* The first 512KB is the secure firmware's, which PSCI runs from. */
#define	RESERVEDLOW	0x80000

/*
 * The allocator pools' ceilings, as fractions of memory (../arm64/main.c).
 * The 3B+'s defaults let the three reach half of memory together, which
 * on a 4GB board left 2GB that nothing could allocate: here they add up
 * to all of it, the Dis heap taking half. poolsize takes an int, and
 * half of memory below RAMLIMIT is under 2GB, so none of them wraps.
 */
#define	MAINDIV		4
#define	HEAPDIV		2
#define	IMAGDIV		4

/*
 * Ethernet input queue per conversation (../port/devether.c): GENET is
 * gigabit and receives into 2KB buffers; 1MB is about 450 frames, 8ms.
 */
#define	ETHERQLIMIT	(1024*1024)
#define	ETHEROQLIMIT	(1024*1024)	/* and out: the same 1MB */
#define	ETHEROQWAITMS	50		/* a full output queue makes its writer wait this long before dropping */
#define	TCPWQLIMIT	(1024*1024)	/* a TCP connection's send queue, when windows are scaled (../ip/tcp.c) */

/* The card is on the SoC's SDHCI: emmc2.c. The radio is on its second: radio.c. */
#define	SOCRADIO	1
#define	NVME0		1	/* ../port/devsd.c serves #S/nvme0: nvme.c */
#define	FWRTC		1	/* #P has fan, fanrpm, led, button; devcons sets the clock: rtcfan.c */
#define	RP1GPIO		1	/* ../bcm/devgpio.c: its interrupts are RP1's */
#define	SDCARD_EMMC2	1
#define	SDCARD_HISPEED	1	/* ../bcm/sdmmc.c: CMD6 to 50MHz */

/*
 * Cortex-A76 L1 data cache line: 64 bytes, as the A53's is. Upstream's bcm port says 32, which is
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
 * Where the kernel image sits: kernel.ld says why it is not 0x80000.
 */
#define	KTZERO		0x200000
