/*
 * os/amd64/arch.S -- setlabel/gotolabel and the atomic test-and-set.
 *
 * setlabel/gotolabel are setjmp/longjmp for the kernel: the error
 * machinery (waserror/nexterror) and the scheduler both use them.  The
 * pairing is Plan 9's: setlabel returns 0, and a later gotolabel
 * resumes as if setlabel had returned 1.
 *
 * The stack pointer must be saved AFTER the return address would have
 * been popped, because gotolabel jumps to the saved pc instead of
 * returning through it.  Saving rsp+8 at entry makes the resumed caller
 * see exactly the stack it had when setlabel returned.
 *
 * Callee-saved registers are saved because gotolabel re-enters the
 * frame from deeper in the call chain, skipping the epilogues that
 * would have restored them.  Order must match dat.h: sp 0, pc 8,
 * rbx/rbp/r12-r15 at 16.
 */

	.section .text
	.code64

	.globl	setlabel
setlabel:
	leaq	8(%rsp), %rax		/* sp as it is after the call returns */
	movq	%rax, 0(%rdi)
	movq	(%rsp), %rax		/* the resume pc */
	movq	%rax, 8(%rdi)
	movq	%rbx, 16(%rdi)
	movq	%rbp, 24(%rdi)
	movq	%r12, 32(%rdi)
	movq	%r13, 40(%rdi)
	movq	%r14, 48(%rdi)
	movq	%r15, 56(%rdi)
	xorl	%eax, %eax		/* first return: 0 */
	ret

	.globl	gotolabel
gotolabel:
	movq	16(%rdi), %rbx
	movq	24(%rdi), %rbp
	movq	32(%rdi), %r12
	movq	40(%rdi), %r13
	movq	48(%rdi), %r14
	movq	56(%rdi), %r15
	movq	0(%rdi), %rsp
	movq	8(%rdi), %rdx
	movl	$1, %eax		/* resumed return: 1 */
	jmp	*%rdx

/*
 * ulong _tas(ulong *key): test and set, returning the old value.
 * The kernel's spin locks (os/port/taslock.c) call this; it must be a
 * full-width exchange, since Lock.key is a ulong.
 */
	.globl	_tas
_tas:
	movq	$1, %rax
	xchgq	%rax, (%rdi)
	ret
