/*
 * Instruction-cache synchronisation for riscv64 Linux
 *
 * fence.i orders only the hart that executes it, and a thread may
 * migrate to another hart between writing JIT code and running it.
 * The GCC builtin calls the riscv_flush_icache system call, which
 * makes the kernel synchronise every hart's instruction stream (and
 * any hart the thread later migrates to), so it is the right primitive
 * here -- not a bare fence.i.
 */

#include "dat.h"

int
segflush(void *a, ulong n)
{
	if(n)
		__builtin___clear_cache((char*)a, (char*)a + n);
	return 0;
}
