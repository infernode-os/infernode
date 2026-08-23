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
