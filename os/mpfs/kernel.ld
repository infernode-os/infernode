/*
 * A PolarFire SoC: the Hart Software Services' OpenSBI (or QEMU's
 * -bios on the Icicle Kit model) is in the first 2MB of DDR, at
 * 0x80000000, and enters the kernel at 0x80200000 -- where the HSS
 * places a U54 payload. .text.boot first, so _start is exactly there.
 * The rest is ../riscvvirt/kernel.ld's.
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
