/*
 * lib9.h for the native (bare-metal) amd64 kernel.
 *
 * libkern's sources include <lib9.h>, and in the native build that must
 * resolve to THIS header, not to a hosted one.  Deliberately thin, as in
 * Inferno/arm64/include/lib9.h: the type vocabulary comes from u.h and
 * the libc declarations from kern.h.
 */

#include <u.h>
#include <kern.h>

#define __LITTLE_ENDIAN		/* for libmath's dtoa.c */
