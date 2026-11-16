/*
 * LD_PRELOAD for tests/host/jit_4gb_test.sh: puts one of the JIT's
 * executable mappings at a multiple of 4GB, where address-space
 * randomisation puts one for a launch in a thousand or so.
 *
 * comp-amd64.c's jitmalloc() asks for memory near the emulator's text
 * with an address hint, and takes what it is given if that is within
 * 1.75GB of the text.  The first such mapping made after the file
 * named by $JIT4GB_ARM exists (the Limbo side of the test creates it
 * just before it loads a module) is made instead at the 4GB boundary
 * below the hint, or the one above, whichever is near enough; the file
 * is removed and a line says where the mapping went.  If neither
 * boundary is near enough, or the place is taken, the line says so and
 * the test tries another launch.
 */
#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

#define NEAR	0x6c000000ULL	/* jitmalloc's 0x70000000, less the 64MB its hints range over */

static void*
rawmmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	return (void*)syscall(SYS_mmap, addr, len, prot, flags, fd, off);
}

static void*
shimmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	void *p, *q;
	char *arm;
	uintptr_t hint, t;

	p = rawmmap(addr, len, prot, flags, fd, off);
	if(!(prot & PROT_EXEC) || addr == NULL || p != addr)
		return p;
	arm = getenv("JIT4GB_ARM");
	if(arm == NULL || access(arm, F_OK) != 0)
		return p;
	unlink(arm);
	hint = (uintptr_t)addr;
	t = hint & ~(uintptr_t)0xFFFFFFFF;
	if(hint - t >= NEAR || t == 0)
		t += (uintptr_t)1 << 32;
	if((t > hint ? t - hint : hint - t) >= NEAR){
		fprintf(stderr, "jit_4gb: no 4GB boundary near %p\n", addr);
		return p;
	}
	q = rawmmap((void*)t, len, prot, flags|MAP_FIXED_NOREPLACE, fd, off);
	if(q != (void*)t){
		if(q != MAP_FAILED)
			munmap(q, len);
		fprintf(stderr, "jit_4gb: could not map at %p\n", (void*)t);
		return p;
	}
	munmap(p, len);
	fprintf(stderr, "jit_4gb: text moved to %p\n", q);
	return q;
}

void*
mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	return shimmap(addr, len, prot, flags, fd, off);
}

void*
mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	return shimmap(addr, len, prot, flags, fd, off);
}
