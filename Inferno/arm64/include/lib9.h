/*
 * lib9.h for the native (bare-metal) arm64 kernel.
 *
 * libkern's sources include <lib9.h>, and in the native build that must
 * resolve to THIS header, not to the hosted MacOSX/arm64/include/lib9.h.
 * The hosted one pulls in stdio.h, setjmp.h, time.h and ctype.h, none of
 * which exist with no operating system underneath.
 *
 * Deliberately thin, matching upstream's Inferno/arm/include/lib9.h: the
 * type vocabulary comes from u.h and the libc declarations from kern.h,
 * so there is exactly one definition of each and no opportunity for the
 * hosted and native trees to disagree about how wide a ulong is.
 */

#include <u.h>
#include <kern.h>

#define __LITTLE_ENDIAN		/* for libmath's dtoa.c */

