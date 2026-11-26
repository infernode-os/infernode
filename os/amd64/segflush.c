/*
 * os/amd64/segflush.c -- make freshly written code visible.
 *
 * The amd64 JIT writes instruction bytes into ordinary kernel memory
 * and then calls the result.  x86 has a coherent instruction cache, and
 * nothing here rewrites code that has already run -- a module's text is
 * compiled once, before anything jumps into it -- so no cache
 * maintenance is required.  A serialising instruction is: it drains the
 * pipeline of instructions fetched before the stores that wrote the
 * code.  The hosted builds use mprotect here instead, which a kernel
 * with no page protection has no equivalent for.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

int
segflush(void *va, ulong n)
{
	uintptr a;

	USED(va);
	USED(n);
	__sync_synchronize();
	__asm__ volatile("cpuid" : "=a"(a) : "a"(0) : "rbx", "rcx", "rdx");
	USED(a);
	return 0;
}
