/*
 * Memory layout and machine constants for os/amd64.
 *
 * os/port expects each platform to supply this.  The address map is a
 * flat identity for the first GiB, so KADDR and PADDR are the identity;
 * they exist as macros so upstream call sites stay intact.
 */

#define	BY2WD		8			/* bytes per word (LP64) */
#define	BY2V		8			/* bytes per vlong */
#define	BY2PG		4096			/* bytes per page */
#define	WD2PG		(BY2PG/BY2WD)		/* words per page */
#define	PGSHIFT		12			/* log2(BY2PG) */
#define	PGROUND(s)	(((s)+(BY2PG-1))&~(BY2PG-1))
#define	ROUND(s, sz)	(((s)+((sz)-1))&~((sz)-1))

/*
 * Timer frequency.  The mini kernel's trap.h has the same value; when
 * os/port's clock replaces the 8254 setup, that copy goes away.
 */
#ifndef	HZ
#define	HZ		100			/* clock ticks per second */
#endif
#define	MS2HZ		(1000/HZ)		/* milliseconds per tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

#define	MAXMACH		1			/* processors */
#define	KSTACK		(16*1024)		/* kernel stack per process */
#define	CACHELINESZ	64

#define	KZERO		0			/* kernel address zero */
#define	KADDR(a)	((void*)(uintptr)(a))
#define	PADDR(a)	((uintptr)(a))
#define	KTZERO		0x100000		/* where the kernel is loaded */

#define	MACHP(n)	(&machs[n])
