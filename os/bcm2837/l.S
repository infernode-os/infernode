/*
 * AArch64 reset entry for BCM2837 (Raspberry Pi 3B+).
 *
 * All four Cortex-A53 cores are released at the kernel load address by
 * the VideoCore firmware, so the first job is to park cores 1-3 and let
 * core 0 alone proceed.  The parked cores sit in wfe; bringing them up
 * later means writing an entry address to their mailbox and issuing sev.
 *
 * Note: do not assume the PC at entry.  QEMU's raspi3b starts execution
 * at 0x0 behind a small firmware shim that branches to the load address,
 * whereas real hardware enters directly.  Everything here is written
 * position-independently or via the linker-supplied symbols.
 */

.section ".text.boot"
.global _start

_start:
	mrs	x0, mpidr_el1
	and	x0, x0, #3
	cbz	x0, core0

	/* cores 1-3: park until woken */
park:
	wfe
	b	park

core0:
	/*
	 * Stack grows down from the kernel load address, into the
	 * memory below _start which the firmware leaves free.
	 */
	ldr	x0, =_start
	mov	sp, x0

	/* zero .bss */
	ldr	x1, =__bss_start
	ldr	x2, =__bss_end
clrbss:
	cmp	x1, x2
	b.ge	callmain
	str	xzr, [x1], #8
	b	clrbss

callmain:
	bl	kmain

	/* kmain must not return; park if it does */
	b	park
