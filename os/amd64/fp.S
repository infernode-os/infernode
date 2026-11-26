/*
 * os/amd64/fp.S -- the floating point state a process owns.
 *
 * Dis has a REAL type, so libinterp needs the SSE registers, and a
 * process that is preempted in the middle of a calculation must find
 * them as it left them.  FXSAVE64/FXRSTOR64 is the unit of that: 512
 * bytes holding the x87 stack, XMM0-XMM15 and MXCSR, and it is exactly
 * what the FPU/FPenv structs in dat.h reserve.
 *
 * FXSAVE requires its destination to be 16-byte aligned and raises
 * #GP otherwise.  The destination is the FPU in a Proc (page-aligned
 * arena, so fine) or the FPenv in a Prog's Osenv, which may be a
 * malloc'd block at an odd offset -- os/port/dis.c makes one with
 * "malloc(sizeof(Prog)+sizeof(Osenv))".  So both routines save to an
 * aligned slot on the stack and copy; correctness does not depend on
 * an allocator's alignment.
 *
 * The copy is 64 qwords with REP MOVSQ, not SSE: the kernel core is
 * built -mno-sse on purpose (no interrupt path may dirty FP state that
 * is not being saved), and FPrestore must not touch a register before
 * FXRSTOR has installed the state it is restoring.  RDI/RSI/RCX are
 * caller-saved under the SysV ABI.
 */

	.section .text
	.code64

/* void FPsave(void *p) */
	.globl	FPsave
FPsave:
	pushq	%rbp
	movq	%rsp, %rbp
	andq	$-16, %rsp
	subq	$512, %rsp
	fxsave64 (%rsp)
	movq	%rdi, %rdx
	movq	%rsp, %rsi
	movq	%rdx, %rdi
	movl	$64, %ecx
	cld
	rep movsq
	movq	%rbp, %rsp
	popq	%rbp
	ret

/* void FPrestore(void *p) */
	.globl	FPrestore
FPrestore:
	pushq	%rbp
	movq	%rsp, %rbp
	andq	$-16, %rsp
	subq	$512, %rsp
	movq	%rdi, %rsi
	movq	%rsp, %rdi
	movl	$64, %ecx
	cld
	rep movsq
	fxrstor64 (%rsp)
	movq	%rbp, %rsp
	popq	%rbp
	ret

/*
 * void fpinit(void) -- install the architectural reset state and record
 * it as initfp, the image a new process starts with.
 *
 * os/port/portfns.h maps FPinit() to this name when the math library
 * is linked.  FNINIT plus the default MXCSR (0x1F80: all exceptions
 * masked, round to nearest) is what a process gets when it is created.
 */
	.globl	fpinit
fpinit:
	pushq	%rbp
	movq	%rsp, %rbp
	andq	$-16, %rsp
	subq	$512, %rsp
	fninit
	ldmxcsr	initmxcsr(%rip)
	fxsave64 (%rsp)
	leaq	initfp(%rip), %rdi
	movq	%rsp, %rsi
	movl	$64, %ecx
	cld
	rep movsq
	movq	%rbp, %rsp
	popq	%rbp
	ret

	.section .rodata
	.align	4
initmxcsr:
	.long	0x1f80
