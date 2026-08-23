/*
 * Minimal freestanding type vocabulary for the bare-metal kernel.
 *
 * The tree's include/lib9.h cannot be used here: it pulls in stdio.h,
 * setjmp.h, time.h and friends, none of which exist when there is no
 * host OS underneath.  These typedefs deliberately mirror the names
 * lib9.h defines so that code moving between the hosted and native
 * trees reads the same.
 */

#define nil	((void*)0)

typedef unsigned char		uchar;
typedef unsigned short		ushort;
typedef unsigned int		uint;
typedef signed char		schar;
typedef long long		vlong;
typedef unsigned long long	uvlong;

typedef unsigned char		u8int;
typedef unsigned short		u16int;
typedef unsigned int		u32int;
typedef unsigned long long	u64int;

typedef unsigned long		uintptr;
typedef long			intptr;

/*
 * Forward declaration so fns.h can prototype the trap handlers without
 * dragging in ureg.h everywhere.
 */
typedef struct Ureg Ureg;

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
