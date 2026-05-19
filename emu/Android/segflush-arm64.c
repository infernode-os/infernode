/*
 * Cache flush for ARM64 Linux
 *
 * ARM64 doesn't have the __ARM_NR_cacheflush syscall that 32-bit ARM has.
 * Instead we use the GCC builtin which generates the appropriate
 * DC (data cache) and IC (instruction cache) instructions.
 */

#include "dat.h"

int
segflush(void *a, ulong n)
{
	if(n)
		__builtin___clear_cache((char*)a, (char*)a + n);
	return 0;
}
