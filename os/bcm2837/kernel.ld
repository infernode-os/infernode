/*
 * The AArch64 boot protocol on the Raspberry Pi loads kernel8.img at
 * 0x80000 (the 32-bit kernel.img loads at 0x8000 instead).  .text.boot
 * must come first so that _start lands exactly on the load address.
 */

ENTRY(_start)

SECTIONS
{
	. = 0x80000;

	.text : {
		KEEP(*(.text.boot))
		*(.text*)
	}

	.rodata : { *(.rodata*) }
	.data   : { *(.data*) }

	/*
	 * The last byte that is IN the image file.
	 *
	 * objcopy -O binary stops at the end of .data, while __bss_start
	 * is aligned past it -- so a snapshot taken to __bss_start is a
	 * few bytes longer than the file it is meant to be a copy of.
	 * Harmless when booted, since those bytes land in .bss and are
	 * cleared, but it means a checksum of the installed kernel does
	 * not match a checksum of the file.
	 */
	edata = .;

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
	 * the top of ARM-visible memory is free for xalloc to hand out.
	 * Page-aligned because that is the unit xalloc counts in.
	 */
	. = ALIGN(4096);
	end = .;

	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
