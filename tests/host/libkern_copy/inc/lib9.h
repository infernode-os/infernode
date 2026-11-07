/*
 * What libkern/memmove.c and memset.c need of the kernel's lib9.h, for
 * building them on the host (tests/host/libkern_copy_test.sh). The
 * test compiles them with memmove, memcpy and memset renamed, so the
 * host's own are not replaced.
 */
typedef unsigned char		uchar;
typedef unsigned long		ulong;
typedef unsigned long long	uvlong;
typedef unsigned long		uintptr;

void*	memmove(void*, void*, ulong);
void*	memcpy(void*, void*, ulong);
void*	memset(void*, int, ulong);
