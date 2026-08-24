/*
 * AArch64 exception vectors.
 *
 * VBAR_EL1 must be 2048-byte aligned and the table is sixteen slots of
 * 128 bytes: four groups (current EL on SP_EL0, current EL on SP_ELx,
 * lower EL in AArch64, lower EL in AArch32) of four kinds (synchronous,
 * IRQ, FIQ, SError).  128 bytes is not much, so each slot only records
 * which one it was and branches to the common path.
 *
 * The frame built here is struct Ureg from ureg.h.  The two must agree;
 * nothing checks it for us.
 */

#include "ureg.h"

/*
 * One vector slot: stash the slot number and jump to the common entry.
 * x18 is used as the scratch because it is the platform register and
 * nothing here has claimed it; it is saved with the rest of the frame.
 */
.macro	VEC, type
	.align	7
	msr	tpidr_el1, x18		/* park x18 so we have a scratch */
	mov	x18, #\type
	b	exccommon
.endm

	.section ".text"
	.align	11
	.global	vectors
vectors:
	VEC	0			/* current EL, SP_EL0 */
	VEC	1
	VEC	2
	VEC	3

	VEC	4			/* current EL, SP_ELx */
	VEC	5
	VEC	6
	VEC	7

	VEC	8			/* lower EL, AArch64 */
	VEC	9
	VEC	10
	VEC	11

	VEC	12			/* lower EL, AArch32 */
	VEC	13
	VEC	14
	VEC	15

/*
 * The emergency exception stack.
 *
 * AArch64 does not switch stacks for an exception taken at the same EL
 * on SP_ELx: the handler pushes its frame onto whatever sp already
 * holds.  So a corrupted sp does not merely crash -- it makes the crash
 * unreportable.  The fault handler writes the Ureg through the bad
 * pointer, faults again, re-enters here, and loops, scribbling as it
 * goes.  Observed directly: sp landed in .rodata, and the console
 * filled with half-printed copies of "*** unhandled exception ***"
 * while the register dump that would have identified the original fault
 * was overwritten each time round.
 *
 * That is the difference between a bug with a diagnosis and a bug
 * without one, and on real hardware there is no debugger to fall back
 * on.
 */
	.set	EXCSTACKSIZE, 4096

	.section ".bss"
	.align	4
excstack:
	.space	EXCSTACKSIZE
excstacktop:

	.section ".text"

/*
 * Common exception entry.  On arrival x18 holds the slot number and the
 * caller's x18 is in tpidr_el1.
 */
exccommon:
	/*
	 * Two more scratch registers, parked in the thread-ID registers.
	 * Nothing else in this kernel uses either, and unlike a stack slot
	 * they are reachable when sp is exactly what is in doubt.
	 */
	msr	tpidr_el0, x16
	msr	tpidrro_el0, x17

	/*
	 * The one range an sp can never legitimately be in is the kernel's
	 * own text, rodata and data -- [_start, __bss_start).  Everything
	 * else is fair game: a boot stack may sit below the image (bcm2837
	 * loads at 0x80000 and stacks below it) or inside .bss (virt), and
	 * process stacks come from the heap above `end`.
	 *
	 * Testing that window rather than "inside the image" matters: an
	 * earlier version of this check used the image base and `end`, which
	 * declared virt's .bss boot stack bogus and switched stacks on every
	 * exception it took -- turning a diagnostic into a second bug.
	 */
	mov	x16, sp
	adrp	x17, _start
	add	x17, x17, :lo12:_start
	cmp	x16, x17
	b.lo	1f				/* below the image entirely */
	adrp	x17, __bss_start
	add	x17, x17, :lo12:__bss_start
	cmp	x16, x17
	b.hs	1f				/* .bss or heap: a real stack */

	/*
	 * Bogus.  Move to the emergency stack so the frame lands somewhere
	 * real and trap() gets a chance to report.
	 */
	adrp	x17, excstacktop
	add	x17, x17, :lo12:excstacktop
	mov	sp, x17
1:
	sub	sp, sp, #UREGSIZE

	/*
	 * x0 and x1 are saved first, which makes them the only registers
	 * free to work with.  x1 carries the sp the interrupted code
	 * actually had -- which is the whole point when it was the bogus
	 * one, since sp+UREGSIZE would now report the emergency stack and
	 * quietly hide the very value being diagnosed.  x16 is restored
	 * immediately after, so the frame still records it correctly.
	 */
	stp	x0, x1, [sp, #16*0]
	mov	x1, x16
	mrs	x16, tpidr_el0
	mrs	x17, tpidrro_el0

	stp	x2, x3, [sp, #16*1]
	stp	x4, x5, [sp, #16*2]
	stp	x6, x7, [sp, #16*3]
	stp	x8, x9, [sp, #16*4]
	stp	x10, x11, [sp, #16*5]
	stp	x12, x13, [sp, #16*6]
	stp	x14, x15, [sp, #16*7]
	stp	x16, x17, [sp, #16*8]

	/* recover the interrupted x18, then save it with x19 */
	mrs	x0, tpidr_el1
	stp	x0, x19, [sp, #16*9]

	stp	x20, x21, [sp, #16*10]
	stp	x22, x23, [sp, #16*11]
	stp	x24, x25, [sp, #16*12]
	stp	x26, x27, [sp, #16*13]
	stp	x28, x29, [sp, #16*14]

	/* x30, and the sp the interrupted code was using (kept in x1) */
	stp	x30, x1, [sp, #16*15]

	mrs	x0, elr_el1
	mrs	x1, spsr_el1
	stp	x0, x1, [sp, #16*16]

	mrs	x0, esr_el1
	mrs	x1, far_el1
	stp	x0, x1, [sp, #16*17]

	/* slot number, still in x18 */
	stp	x18, xzr, [sp, #16*18]

	mov	x0, sp			/* struct Ureg* */
	bl	trap

	/* fall through to return */

	.global	excreturn
excreturn:
	ldp	x0, x1, [sp, #16*16]
	msr	elr_el1, x0
	msr	spsr_el1, x1

	ldp	x0, x1, [sp, #16*0]
	ldp	x2, x3, [sp, #16*1]
	ldp	x4, x5, [sp, #16*2]
	ldp	x6, x7, [sp, #16*3]
	ldp	x8, x9, [sp, #16*4]
	ldp	x10, x11, [sp, #16*5]
	ldp	x12, x13, [sp, #16*6]
	ldp	x14, x15, [sp, #16*7]
	ldp	x16, x17, [sp, #16*8]
	ldp	x18, x19, [sp, #16*9]
	ldp	x20, x21, [sp, #16*10]
	ldp	x22, x23, [sp, #16*11]
	ldp	x24, x25, [sp, #16*12]
	ldp	x26, x27, [sp, #16*13]
	ldp	x28, x29, [sp, #16*14]
	ldr	x30, [sp, #16*15]

	add	sp, sp, #UREGSIZE
	eret

/*
 * Install the table.  Called from C once the stack is up.
 */
	.global	trapinit
trapinit:
	adr	x0, vectors
	msr	vbar_el1, x0
	isb
	ret
