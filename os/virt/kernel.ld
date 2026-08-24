/*
 * QEMU loads a raw AArch64 -kernel image at the machine's RAM base plus
 * 0x80000. On virt that is 0x40000000 + 0x80000, and execution starts
 * there directly rather than behind a firmware shim -- so .text.boot
 * must be first, and _start must land exactly on the load address.
 *
 * Keep this address in step with KTZERO in mem.h.
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
	.data   : { *(.data*) }

	. = ALIGN(16);
	__bss_start = .;
	.bss : {
		*(.bss*)
		*(COMMON)
	}
	. = ALIGN(16);
	__bss_end = .;

	/*
	 * First address past the kernel image. Everything from here to
	 * the top of RAM is free for xalloc to hand out. Page-aligned
	 * because that is the unit xalloc counts in.
	 */
	. = ALIGN(4096);
	end = .;

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
