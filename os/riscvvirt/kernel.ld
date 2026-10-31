/*
 * QEMU's RISC-V virt machine: OpenSBI (-bios default) takes the first
 * 2MB of RAM, which starts at 0x80000000, and enters the kernel at
 * 0x80200000. .text.boot first, so _start is exactly there.
 *
 * The rest is ../virt/kernel.ld: the sections and symbols the kernel
 * is written against do not depend on the machine, only the address.
 */

ENTRY(_start)

SECTIONS
{
	. = 0x80200000;

	.text : {
		KEEP(*(.text.boot))
		*(.text*)
	}

	.rodata : { *(.rodata*) *(.srodata*) }
	/* RISC-V compilers put small objects in .sdata and .sbss: keep them
	 * inside the ranges l.S stashes and clears */
	.data   : { __data_start = .; *(.data*) *(.sdata*) }

	edata = .;

	. = ALIGN(16);
	__bss_start = .;
	.bss : {
		*(.sbss*)
		*(.bss*)
		*(COMMON)
	}
	. = ALIGN(16);
	__bss_end = .;

	/* l.S copies .data here before anything writes to it; see #B */
	.datastash (NOLOAD) : {
		__datastash = .;
		. += SIZEOF(.data) + 16;
	}

	. = ALIGN(4096);
	end = .;

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
