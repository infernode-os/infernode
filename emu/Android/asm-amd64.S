/*
 * amd64 (x86_64) assembly routines for Linux
 *
 * System V AMD64 ABI:
 *   Arguments: rdi, rsi, rdx, rcx, r8, r9
 *   Return: rax (and rdx for 128-bit)
 *   Caller-saved: rax, rcx, rdx, rsi, rdi, r8-r11
 *   Callee-saved: rbx, rbp, r12-r15
 *   Stack: 16-byte aligned before call
 */

	.file	"asm-amd64.S"
	.text

/*
 * int _tas(int *p)
 *
 * Test-and-set: atomically exchange *p with 1, return old value.
 * rdi = pointer to int
 */
	.globl	_tas
	.type	_tas, @function
_tas:
	movl	$1, %eax
	xchgl	%eax, (%rdi)
	ret
	.size	_tas, .-_tas

/*
 * ulong umult(ulong m1, ulong m2, ulong *hi)
 *
 * 64-bit multiply returning 128-bit result.
 * rdi = m1, rsi = m2, rdx = pointer to store high 64 bits
 * Returns: low 64 bits in rax
 */
	.globl	umult
	.type	umult, @function
umult:
	movq	%rdx, %r8	/* save hi pointer (rdx will be clobbered) */
	movq	%rdi, %rax	/* m1 */
	mulq	%rsi		/* rdx:rax = rax * rsi */
	movq	%rdx, (%r8)	/* store high bits */
	ret			/* low bits already in rax */
	.size	umult, .-umult

/*
 * void FPsave(void *p)
 *
 * Save floating-point state.
 * On x86_64 Linux with pthreads, FP context is handled automatically
 * by the OS. We provide no-op stubs for compatibility.
 * rdi = pointer to save area (unused)
 */
	.globl	FPsave
	.type	FPsave, @function
FPsave:
	ret
	.size	FPsave, .-FPsave

/*
 * void FPrestore(void *p)
 *
 * Restore floating-point state.
 * rdi = pointer to save area (unused)
 */
	.globl	FPrestore
	.type	FPrestore, @function
FPrestore:
	ret
	.size	FPrestore, .-FPrestore

/*
 * uintptr getcallerpc(void *dummy)
 *
 * Return the return address of the caller.
 * On amd64, return address is at 8(%rbp) if frame pointer is used,
 * but we use the more reliable approach of reading from stack.
 */
	.globl	getcallerpc
	.type	getcallerpc, @function
getcallerpc:
	movq	8(%rbp), %rax
	ret
	.size	getcallerpc, .-getcallerpc

/*
 * void executeonnewstack(void *tos, void (*tramp)(void *arg), void *arg)
 *
 * Switch to a new stack and call the trampoline function.
 * rdi = new stack top
 * rsi = trampoline function
 * rdx = argument to pass
 */
	.globl	executeonnewstack
	.type	executeonnewstack, @function
executeonnewstack:
	movq	%rdi, %rsp	/* switch to new stack */
	movq	%rdx, %rdi	/* arg becomes first argument to tramp */
	xorq	%rbp, %rbp	/* clear frame pointer to stop backtrace */
	call	*%rsi		/* call tramp(arg) */
	/* if we return, exit */
	movq	$60, %rax	/* sys_exit */
	xorq	%rdi, %rdi	/* status = 0 */
	syscall
	.size	executeonnewstack, .-executeonnewstack

/*
 * void unlockandexit(int *key)
 *
 * Unlock the key and exit the thread.
 * rdi = pointer to lock
 */
	.globl	unlockandexit
	.type	unlockandexit, @function
unlockandexit:
	movl	$0, (%rdi)	/* unlock */
	movq	$60, %rax	/* sys_exit */
	xorq	%rdi, %rdi	/* status = 0 */
	syscall
	.size	unlockandexit, .-unlockandexit
