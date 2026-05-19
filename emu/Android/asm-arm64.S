/*
 * arm64 assembly routines for Linux
 *
 * Note: Linux arm64 does NOT use underscore prefix for C symbols
 * ABI: x0-x7 args, x0 return, x8 indirect result, x9-x15 temps
 *      x16-x17 intra-procedure-call, x18 platform reserved
 *      x19-x28 callee-saved, x29 FP, x30 LR, x31 SP/ZR
 */

	.file	"asm-arm64.S"
	.text
	.align 2

/*
 * int _tas(int *p)
 *
 * Test-and-set: atomically read *p and set it to non-zero.
 * Returns the old value.
 *
 * x0 = pointer to int
 * Returns: old value in x0
 */
	.global	_tas
	.type	_tas, %function
_tas:
	mov	w1, #1		/* value to store */
1:
	ldaxr	w2, [x0]	/* load exclusive with acquire */
	cbnz	w2, 2f		/* if already set, return old value */
	stlxr	w3, w1, [x0]	/* store exclusive with release */
	cbnz	w3, 1b		/* retry if store failed */
2:
	mov	w0, w2		/* return old value */
	ret
	.size	_tas, .-_tas

/*
 * void FPsave(void *p)
 *
 * Save floating-point state (stub - not needed on arm64 Linux)
 * The kernel handles FP context switching automatically.
 */
	.global	FPsave
	.type	FPsave, %function
FPsave:
	ret
	.size	FPsave, .-FPsave

/*
 * void FPrestore(void *p)
 *
 * Restore floating-point state (stub - not needed on arm64 Linux)
 */
	.global	FPrestore
	.type	FPrestore, %function
FPrestore:
	ret
	.size	FPrestore, .-FPrestore

/*
 * ulong umult(ulong m1, ulong m2, ulong *hi)
 *
 * 64-bit multiply returning 128-bit result
 * x0 = m1, x1 = m2, x2 = pointer to store high 64 bits
 * Returns: low 64 bits in x0
 */
	.global	umult
	.type	umult, %function
umult:
	umulh	x3, x0, x1	/* high 64 bits */
	mul	x0, x0, x1	/* low 64 bits */
	str	x3, [x2]	/* store high bits */
	ret
	.size	umult, .-umult
