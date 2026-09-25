/*
 * riscv64 assembly routines for Linux
 *
 * ABI (LP64D): a0-a7 args, a0 return, t0-t6 temps,
 *      s0-s11 callee-saved, ra return address, sp stack,
 *      gp/tp reserved
 */

	.file	"asm-riscv64.S"
	.text
	.align 2

/*
 * int _tas(int *p)
 *
 * Test-and-set: atomically read *p and set it to non-zero.
 * Returns the old value.  amoswap with acquire+release ordering
 * is the lock-acquire idiom; the unlock side (a plain store of 0
 * in lock.c) is preceded by the compiler's release fence.
 */
	.global	_tas
	.type	_tas, @function
_tas:
	li	t0, 1
	amoswap.w.aqrl	a0, t0, (a0)
	ret
	.size	_tas, .-_tas

/*
 * void FPsave(void *p)
 * void FPrestore(void *p)
 *
 * Stubs: the Linux kernel saves and restores the F/D registers and
 * fcsr on every context switch, as it does on arm64.
 */
	.global	FPsave
	.type	FPsave, @function
FPsave:
	ret
	.size	FPsave, .-FPsave

	.global	FPrestore
	.type	FPrestore, @function
FPrestore:
	ret
	.size	FPrestore, .-FPrestore

/*
 * ulong umult(ulong m1, ulong m2, ulong *hi)
 *
 * 64x64 -> 128 unsigned multiply: low half returned, high half
 * stored through hi.
 */
	.global	umult
	.type	umult, @function
umult:
	mulhu	t0, a0, a1
	mul	a0, a0, a1
	sd	t0, 0(a2)
	ret
	.size	umult, .-umult

	.section .note.GNU-stack,"",@progbits
