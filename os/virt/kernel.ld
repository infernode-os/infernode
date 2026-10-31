/*
 * QEMU's `virt` machine loads a flat arm64 image 0x80000 above the base
 * of RAM, which is at 0x40000000.  .text.boot must come first so that
 * _start lands exactly on the load address.
 *
 * Everything below the first line is os/bcm2837/kernel.ld: the sections
 * and the symbols os/arm64 is written against do not depend on the
 * machine, only the address does.
 */

ENTRY(_start)

SECTIONS
{
	. = 0x40080000;

	.text : {
		KEEP(*(.text.boot))
		*(.text*)
	}

	.rodata : { *(.rodata*) }
	.data   : { __data_start = .; *(.data*) }

	edata = .;

	. = ALIGN(16);
	__bss_start = .;
	.bss : {
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
