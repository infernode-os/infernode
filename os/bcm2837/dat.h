/*
 * Port-specific data types for the bare-metal BCM2837 kernel.
 *
 * The integer vocabulary now comes from Inferno/arm64/include/u.h,
 * which is the same header upstream Inferno's native ports use (one per
 * objtype) and the one os/port will expect.  It replaces the local
 * typedefs this file started with: keeping a second definition of uchar
 * and friends would guarantee the two drifted, and os/port's whole
 * pointer-in-ulong convention depends on getting exactly one answer for
 * how wide these are.
 *
 * The tree's own include/lib9.h is not usable here -- it pulls in
 * stdio.h, setjmp.h and time.h, none of which exist with no host OS
 * underneath.
 *
 * Following Plan 9 convention, this header does NOT include u.h: every
 * .c includes u.h first and dat.h after.  Upstream os/port is written
 * that way throughout, so matching it keeps imported files diff-able
 * against their originals -- and u.h has no include guard, exactly
 * because it is expected to be included once, first, by hand.
 */

/*
 * Forward declaration so fns.h can prototype the trap handlers without
 * dragging in ureg.h everywhere.
 */
typedef struct Ureg Ureg;

typedef struct Lock Lock;
typedef struct Conf Conf;

/*
 * A spin lock.
 *
 * key is the word _tas operates on and is ulong to match upstream's
 * portfns.h declaration of ulong _tas(ulong*). sr holds the interrupt
 * level saved by ilock so iunlock can restore exactly what was found
 * rather than assuming interrupts were enabled. pc records who took it,
 * which is what makes a stuck lock diagnosable instead of a hang.
 *
 * Named members rather than the Plan 9 anonymous embedding used
 * upstream -- see os/bcm2837/README.md for why -fms-extensions is not a
 * safe substitute.
 */
struct Lock
{
	ulong	key;
	ulong	sr;
	uintptr	pc;
	int	pri;
};

/*
 * Machine configuration, filled in at boot. os/port/xalloc.c reads the
 * memory bank fields directly to decide what it may hand out.
 *
 * These are ulong, matching upstream, which is correct here only
 * because ulong is 64 bits: base0/base1 hold addresses.
 */
struct Conf
{
	ulong	nmach;		/* processors */
	ulong	nproc;		/* processes */
	ulong	npage0;		/* pages in bank 0 */
	ulong	npage1;		/* pages in bank 1 */
	ulong	npage;		/* total physical pages */
	ulong	base0;		/* base of bank 0 */
	ulong	base1;		/* base of bank 1 */
	ulong	ialloc;		/* max interrupt-time allocation, bytes */
	ulong	pipeqsize;	/* size in bytes of pipe queues */
	int	nuart;		/* number of uart devices */
};

extern Conf conf;

/*
 * A framebuffer as the VideoCore firmware handed it back.  pitch is the
 * byte stride of a row and is NOT necessarily width*bytes-per-pixel --
 * the firmware pads, and assuming otherwise skews the image.
 */
typedef struct Fbinfo Fbinfo;

struct Fbinfo
{
	uintptr	base;
	u32int	size;
	u32int	pitch;
	u32int	width;
	u32int	height;
	u32int	depth;
};
