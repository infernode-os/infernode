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

/*
 * Context switching for the scheduler.
 *
 * int setlabel(Label *l)
 * void gotolabel(Label *l)
 *
 * setlabel records where execution is and returns 0. gotolabel restores
 * that point, and execution resumes as if setlabel had returned 1 --
 * the classic Plan 9 pairing, and the whole mechanism proc.c's sched()
 * uses to leave one process and enter another.
 *
 * sp, the return address, AND x19-x29 are saved.
 *
 * Saving the callee-saved registers is REQUIRED, not belt-and-braces.
 * It is tempting to argue they survive because setlabel's caller
 * spilled them on entry -- but gotolabel re-enters that frame from
 * deeper in the call chain, skipping every intervening epilogue, and
 * those epilogues are exactly what would have restored them. See the
 * note on struct Label in dat.h for the corruption this produced.
 *
 * Label layout must match dat.h: sp at 0, pc at 8, regs at 16.
 */
	.global	setlabel
setlabel:
	mov	x1, sp
	str	x1, [x0, #0]		/* l->sp */
	str	x30, [x0, #8]		/* l->pc: where to resume */

	/* callee-saved registers: x19-x29, at l->regs (offset 16) */
	stp	x19, x20, [x0, #16]
	stp	x21, x22, [x0, #32]
	stp	x23, x24, [x0, #48]
	stp	x25, x26, [x0, #64]
	stp	x27, x28, [x0, #80]
	str	x29, [x0, #96]

	mov	x0, #0			/* first return: 0 */
	ret

	.global	gotolabel
gotolabel:
	ldp	x19, x20, [x0, #16]
	ldp	x21, x22, [x0, #32]
	ldp	x23, x24, [x0, #48]
	ldp	x25, x26, [x0, #64]
	ldp	x27, x28, [x0, #80]
	ldr	x29, [x0, #96]

	ldr	x1, [x0, #0]
	ldr	x30, [x0, #8]
	mov	sp, x1
	/*
	 * The stack pointer just changed out from under us. dsb/isb are
	 * not needed for that, but the return must not be speculated
	 * against the old frame, and x30 was loaded from memory the
	 * scheduler wrote -- so order the load before the branch.
	 */
	dsb	nsh
	isb
	mov	x0, #1			/* setlabel appears to return 1 */
	ret

/*
 * void fpinit(void)
 *
 * Put FPCR in the state Inferno expects: round to nearest, every
 * floating point exception masked. Masking is not a detail -- Dis
 * defines its arithmetic as non-trapping, so an enabled exception would
 * turn a NaN a Limbo program is entitled to produce into a kernel
 * fault.
 *
 * This lives in assembly because the kernel core is built
 * -mgeneral-regs-only, and clang refuses to even assemble "msr fpcr"
 * under that flag -- it treats FPCR as not existing rather than as a
 * system register it may name. The .arch directive re-enables it for
 * these two instructions only, which is narrower than relaxing the flag
 * for a whole translation unit.
 */
	.arch	armv8-a+fp
	.global	fpinit
fpinit:
	msr	fpcr, xzr		/* RN rounding, all traps disabled */
	msr	fpsr, xzr		/* clear accrued exception flags */
	isb
	ret

/*
 * ulong getcallerpc(void*)
 *
 * os/bcm2837/fns.h defines this as a macro over
 * __builtin_return_address for kernel sources, which is both correct
 * and free. libinterp does not include that header, so it calls this
 * out-of-line version instead, and the two MUST give the same answer.
 *
 * They did not. This returned x30, which at entry is the return address
 * into the function that called getcallerpc -- a PC inside the caller,
 * not the caller's own return address. The macro gives the latter. So
 * every allocator diagnostic raised from libinterp (D2B's poolfault, the
 * lock tracking) reported a PC in a function that had nothing to do with
 * the fault: chasing "alloc:D2B (from 85134/a56d4)" led into
 * eqchantdqid and cvtup, neither of which allocates anything.
 *
 * The caller's return address is its saved x30, one frame up. AAPCS64's
 * standard prologue stores x29/x30 as a pair and sets x29 to the frame
 * base, so the saved link register is at [x29, #8]. This is a leaf, so
 * x29 still belongs to the caller on entry.
 *
 * Both the kernel and libinterp are built -fno-omit-frame-pointer so
 * that frame exists to walk; without it clang may drop x29 at -O2 and
 * this reads whatever the register happened to hold.
 */
	.global	getcallerpc
getcallerpc:
	ldr	x0, [x29, #8]
	ret

/*
 * void cachedwbinvse(void *addr, int len)
 *
 * Clean AND invalidate the data cache over a range, to the Point of
 * Coherency.
 *
 * This is what makes DMA correct, in both directions, and it is not
 * optional: before a device reads a buffer the CPU's dirty lines must
 * be written out or the device sees stale memory, and after a device
 * writes one the CPU's clean lines must be dropped or it reads stale
 * cache. "dc civac" does both, which is why the driver can use one
 * call for either direction.
 *
 * The line size comes from CTR_EL0.DminLine rather than a constant.
 * Upstream's bcm port hardcodes 32, which is right for the ARM11 in a
 * Pi 1 and wrong for the Cortex-A53 here -- and a line size that is
 * too large silently skips lines, which is the failure that presents
 * as rare, load-dependent data corruption rather than as a fault.
 */
/*
 * void cachedwbse(void *addr, int len)
 *
 * Clean (write back) without invalidating -- used before a device
 * READS a buffer, where the CPU's copy stays valid.
 */
	.global	cachedwbse
cachedwbse:
	mrs	x2, ctr_el0
	ubfx	x3, x2, #16, #4
	mov	x4, #4
	lsl	x3, x4, x3
	sub	x4, x3, #1
	add	x1, x0, x1
	bic	x0, x0, x4
1:
	dc	cvac, x0
	add	x0, x0, x3
	cmp	x0, x1
	b.lo	1b
	dsb	sy
	isb
	ret

	.global	cachedwbinvse
cachedwbinvse:
	mrs	x2, ctr_el0
	ubfx	x3, x2, #16, #4		/* DminLine: log2 words per line */
	mov	x4, #4
	lsl	x3, x4, x3		/* line size in bytes */
	sub	x4, x3, #1
	add	x1, x0, x1		/* end address */
	bic	x0, x0, x4		/* round start down to a line */
1:
	dc	civac, x0
	add	x0, x0, x3
	cmp	x0, x1
	b.lo	1b
	dsb	sy
	isb
	ret

/*
 * void FPsave(void*) / void FPrestore(void*)
 *
 * Save and restore the FP/SIMD register file across a context switch,
 * into the FPU struct in dat.h: 32 128-bit V registers then FPCR/FPSR.
 *
 * These matter now rather than later. libinterp is the one part of this
 * kernel compiled with FP, so as soon as two processes run Dis code
 * concurrently their V registers must not be shared. procsave() is
 * where this gets wired in.
 */
	.arch	armv8-a+fp
	.global	FPsave
FPsave:
	stp	q0, q1, [x0, #16*0]
	stp	q2, q3, [x0, #16*2]
	stp	q4, q5, [x0, #16*4]
	stp	q6, q7, [x0, #16*6]
	stp	q8, q9, [x0, #16*8]
	stp	q10, q11, [x0, #16*10]
	stp	q12, q13, [x0, #16*12]
	stp	q14, q15, [x0, #16*14]
	stp	q16, q17, [x0, #16*16]
	stp	q18, q19, [x0, #16*18]
	stp	q20, q21, [x0, #16*20]
	stp	q22, q23, [x0, #16*22]
	stp	q24, q25, [x0, #16*24]
	stp	q26, q27, [x0, #16*26]
	stp	q28, q29, [x0, #16*28]
	stp	q30, q31, [x0, #16*30]
	mrs	x1, fpcr
	str	w1, [x0, #512]
	mrs	x1, fpsr
	str	w1, [x0, #516]
	ret

	.global	FPrestore
FPrestore:
	ldp	q0, q1, [x0, #16*0]
	ldp	q2, q3, [x0, #16*2]
	ldp	q4, q5, [x0, #16*4]
	ldp	q6, q7, [x0, #16*6]
	ldp	q8, q9, [x0, #16*8]
	ldp	q10, q11, [x0, #16*10]
	ldp	q12, q13, [x0, #16*12]
	ldp	q14, q15, [x0, #16*14]
	ldp	q16, q17, [x0, #16*16]
	ldp	q18, q19, [x0, #16*18]
	ldp	q20, q21, [x0, #16*20]
	ldp	q22, q23, [x0, #16*22]
	ldp	q24, q25, [x0, #16*24]
	ldp	q26, q27, [x0, #16*26]
	ldp	q28, q29, [x0, #16*28]
	ldp	q30, q31, [x0, #16*30]
	ldr	w1, [x0, #512]
	msr	fpcr, x1
	ldr	w1, [x0, #516]
	msr	fpsr, x1
	isb
	ret
