#include <lib9.h>
#include <kernel.h>

/*
 * No riscv64 disassembler: print the words, for objdump or a reader
 * (cflag > 4 in comp-riscv64.c).
 */
void
das(u32int *x, int n)
{
	int i;

	for(i = 0; i < n; i++)
		print("\t%.8p %.8ux\n", &x[i], x[i]);
}
