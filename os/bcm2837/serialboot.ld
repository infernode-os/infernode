/*
 * serialboot links at 32MB, not at 0x80000.
 *
 * It has to still be executing while it writes the kernel to the
 * address the boot ROM would have loaded one at, so it cannot live
 * there itself. 32MB is far above anything a kernel image reaches --
 * the current one is under 700KB -- and far below the 948MB this board
 * has, so there is room on both sides.
 */
ENTRY(_start)

SECTIONS
{
	. = 0x2000000;

	.text : {
		KEEP(*(.text.boot))
		*(.text*)
	}
	.rodata : { *(.rodata*) }
	.data   : { *(.data*) }

	. = ALIGN(16);
	__bss_start = .;
	.bss : {
		*(COMMON)
		*(.bss*)
	}
	. = ALIGN(16);
	__bss_end = .;

	end = .;
}
