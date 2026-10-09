/*
 * amd64 (x86_64) assembly routines for macOS
 *
 * Note: macOS uses an underscore prefix for C symbols
 * System V AMD64 ABI: rdi, rsi, rdx, rcx, r8, r9 args, rax return
 */

	.text
	.align 4

/*
 * int _tas(int *p)
 *
 * Test-and-set: atomically exchange *p with 1, return old value.
 * rdi = pointer to int
 */
	.globl __tas
__tas:
	movl	$1, %eax
	xchgl	%eax, (%rdi)
	ret

/*
 * void FPsave(void *p)
 *
 * Save floating-point state (stub - the OS saves it on amd64 macOS)
 */
	.globl _FPsave
_FPsave:
	ret

/*
 * void FPrestore(void *p)
 *
 * Restore floating-point state (stub - the OS saves it on amd64 macOS)
 */
	.globl _FPrestore
_FPrestore:
	ret

/*
 * ulong umult(ulong m1, ulong m2, ulong *hi)
 *
 * 64-bit multiply returning 128-bit result
 * rdi = m1, rsi = m2, rdx = pointer to store high 64 bits
 * Returns: low 64 bits in rax
 */
	.globl _umult
_umult:
	movq	%rdx, %r8	/* save hi pointer (mulq clobbers rdx) */
	movq	%rdi, %rax
	mulq	%rsi		/* rdx:rax = rax * rsi */
	movq	%rdx, (%r8)
	ret
