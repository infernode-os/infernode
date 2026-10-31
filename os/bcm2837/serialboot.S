/*
 * serialboot -- entry stub, and the relocation that makes it possible.
 *
 * A permanent resident of the SD card that pulls the real kernel down
 * the serial line on every reset. It exists so that working on the
 * board does not mean carrying the card between machines, which is not
 * an edit-run loop for anything.
 *
 * THE RELOCATION. The boot ROM loads kernel8.img at 0x80000, which is
 * exactly where the kernel this fetches has to end up -- so the first
 * thing it does is copy itself to 32MB and continue from there, well
 * clear of the address it is about to overwrite. Linking it high and
 * asking the firmware to load it high would work on the board and
 * could not be tested under QEMU, which loads a raw -kernel at
 * 0x80000; relocating makes one binary correct in both places, which
 * matters more than saving twenty instructions.
 *
 * It does NOT drop to EL1 or touch the MMU: the kernel's own _start
 * does both, and doing it here would enter the kernel in a state it
 * does not expect. The only thing carried across the jump is x0, which
 * the firmware sets to the device tree and the kernel reads.
 */
	.section .text.boot
	.global	_start
_start:
	/*
	 * Save the firmware's x0 FIRST. It holds the device tree
	 * pointer and the next instruction needs x0 for something else;
	 * losing it here would hand the kernel a null DTB, and that
	 * failure would surface much later and somewhere unrelated.
	 */
	mov	x19, x0

	/* Park every core but the first -- the firmware leaves them running. */
	mrs	x1, mpidr_el1
	and	x1, x1, #3
	cbz	x1, 2f
1:
	wfe
	b	1b
2:
	/*
	 * Copy ourselves to the link address, using PC-relative
	 * addressing to find where we actually are. adr gives the
	 * runtime address; ldr = gives the link-time one.
	 */
	adr	x2, _start		/* where we are now (0x80000) */
	ldr	x3, =_start		/* where we are linked (32MB) */
	ldr	x4, =__bss_start	/* .bss is not in the image */
	sub	x4, x4, x3		/* how much of us there is */
	cmp	x2, x3
	b.eq	5f			/* already in place */

	mov	x5, xzr
3:
	ldr	x6, [x2, x5]
	str	x6, [x3, x5]
	add	x5, x5, #8
	cmp	x5, x4
	b.lo	3b

	/*
	 * Those stores were data; the next instructions are going to be
	 * fetched from them. With the MMU off the writes have reached
	 * memory, but the instruction side may still hold whatever was
	 * at those addresses before.
	 */
	ic	iallu
	dsb	sy
	isb

	ldr	x6, =5f
	br	x6			/* continue at the link address */
5:
	ldr	x1, =_stack_top
	mov	sp, x1

	bl	bmain			/* returns the entry address */

	mov	x1, x0
	mov	x0, x19			/* the DTB, as the kernel expects */
	br	x1

/*
 * void jumpflush(void)
 *
 * Called once the image is in place. Same reasoning as above: it was
 * written as data and is about to be executed.
 */
	.global	jumpflush
jumpflush:
	ic	iallu
	dsb	sy
	isb
	ret

	.section .bss
	.align	12
_stack:
	.space	4096
	.global	_stack_top
_stack_top:
