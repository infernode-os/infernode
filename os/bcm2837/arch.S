/*
 * AArch64 primitives that cannot be written in C.
 *
 * These are the leaves the rest of the kernel stands on: os/port's
 * taslock.c is written directly against _tas, and everything that takes
 * a lock is written against taslock.c.
 */

	.section ".text"

/*
 * ulong _tas(ulong *addr)
 *
 * Test and set.  Stores 1 at *addr and returns the PREVIOUS value, so a
 * return of 0 means the lock was free and is now ours, and anything else
 * means somebody already held it.  os/port/taslock.c depends on exactly
 * that convention.
 *
 * Written with 64-bit exclusives because upstream's portfns.h declares
 * this as ulong _tas(ulong*), and ulong is 64 bits here.  A 32-bit
 * exclusive would be marginally cheaper but would mean editing the
 * imported prototype and every Lock definition -- not worth diverging
 * from upstream to save one instruction encoding.
 *
 * ldaxr carries acquire semantics, so no load or store inside the
 * critical section can be hoisted above the point where the lock was
 * taken.  The exclusive monitor must be released on the failure path:
 * returning while still holding a reservation can make a later,
 * unrelated stxr fail spuriously.  Hence clrex.
 */
	.global	_tas
_tas:
	mov	x2, #1
1:
	ldaxr	x1, [x0]
	cbnz	x1, 2f			/* already held -- do not store */
	stxr	w3, x2, [x0]
	cbnz	w3, 1b			/* store lost the race; retry */
	mov	x0, #0			/* acquired */
	ret
2:
	clrex				/* drop the reservation before leaving */
	mov	x0, x1			/* old value: non-zero, so held */
	ret

/*
 * void coherence(void)
 *
 * Make prior memory accesses visible in order to other observers.  Used
 * on lock release, where a store that escapes past the unlock would let
 * another core see the lock free while the data it protects is still in
 * flight.
 *
 * dmb rather than dsb: ordering is what is needed, not completion.
 * Inner-shareable covers the four cores of this SoC, which are the only
 * observers that participate in the coherency domain.
 */
	.global	coherence
coherence:
	dmb	ish
	ret

/*
 * Cache maintenance for instructions written as data.
 *
 * void cacheiflush(void *addr, ulong len)
 *
 * The Dis JIT (libinterp/comp-arm64.c) emits code at runtime, and on
 * AArch64 the data and instruction caches are not coherent with each
 * other: freshly written instructions sit in the D-cache while the
 * I-cache still holds whatever was there before.  Clean to the point of
 * unification, then invalidate the I-cache for the same range.
 *
 * This is why JIT bring-up must be validated on real silicon rather than
 * under QEMU -- TCG does not model split I/D caches, so code that omits
 * this runs correctly in the emulator and fails on the board.
 */
	.global	cacheiflush
cacheiflush:
	cbz	x1, 3f

	mrs	x3, ctr_el0
	ubfx	x4, x3, #16, #4		/* DminLine: log2 words per D line */
	mov	x2, #4
	lsl	x2, x2, x4		/* D-cache line size in bytes */

	add	x1, x0, x1		/* end address */
	sub	x4, x2, #1
	bic	x3, x0, x4		/* align start down to a line */
1:
	dc	cvau, x3		/* clean D line to unification point */
	add	x3, x3, x2
	cmp	x3, x1
	b.lo	1b
	dsb	ish

	mrs	x3, ctr_el0
	and	x4, x3, #0xF		/* IminLine: log2 words per I line */
	mov	x2, #4
	lsl	x2, x2, x4		/* I-cache line size in bytes */

	sub	x4, x2, #1
	bic	x3, x0, x4
2:
	ic	ivau, x3		/* invalidate I line */
	add	x3, x3, x2
	cmp	x3, x1
	b.lo	2b
	dsb	ish
	isb
3:
	ret
