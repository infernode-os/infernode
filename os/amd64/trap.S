/*
 * os/amd64/trap.S -- the interrupt entry points.
 *
 * One stub per vector, so the CPU's "did this fault push an error code?"
 * question is answered once at assembly time instead of at run time.  The
 * stubs push a dummy error code where the CPU did not, push the vector,
 * and join a common path that saves the rest of the frame.
 *
 * The common path calls trap(frame) and resumes the frame it returns.
 * That return is the scheduler's switch: trap() stores the interrupted
 * thread's stack pointer and hands back another thread's, so the same
 * restore path resumes whichever thread was chosen.  For a thread that
 * has never run, the frame was built by threadcreate().
 */

	.section .text
	.code64

.macro	isrno num
	.align	16
isr\num:
	pushq	$0			/* no error code from the CPU */
	pushq	$\num
	jmp	isrcommon
.endm

.macro	isrerr num
	.align	16
isr\num:
	pushq	$\num			/* the CPU pushed the error code */
	jmp	isrcommon
.endm

/* exceptions */
	isrno	0
	isrno	1
	isrno	2
	isrno	3
	isrno	4
	isrno	5
	isrno	6
	isrno	7
	isrerr	8
	isrno	9
	isrerr	10
	isrerr	11
	isrerr	12
	isrerr	13
	isrerr	14
	isrno	15
	isrno	16
	isrerr	17
	isrno	18
	isrno	19
	isrno	20
	isrerr	21
	isrno	22
	isrno	23
	isrno	24
	isrno	25
	isrno	26
	isrno	27
	isrno	28
	isrerr	29
	isrerr	30
	isrno	31

/* the 8259's vectors, after the remap to 0x20 */
	isrno	32
	isrno	33
	isrno	34
	isrno	35
	isrno	36
	isrno	37
	isrno	38
	isrno	39
	isrno	40
	isrno	41
	isrno	42
	isrno	43
	isrno	44
	isrno	45
	isrno	46
	isrno	47

isrcommon:
	pushq	%rax
	pushq	%rbx
	pushq	%rcx
	pushq	%rdx
	pushq	%rsi
	pushq	%rdi
	pushq	%rbp
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	cld
	movq	%rsp, %rdi
	andq	$-16, %rsp
	call	trap
	movq	%rax, %rsp
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%r11
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rbp
	popq	%rdi
	popq	%rsi
	popq	%rdx
	popq	%rcx
	popq	%rbx
	popq	%rax
	addq	$16, %rsp		/* vector and error code */
	iretq

	.section .rodata
	.globl	isrtable
isrtable:
	.quad	isr0, isr1, isr2, isr3, isr4, isr5, isr6, isr7
	.quad	isr8, isr9, isr10, isr11, isr12, isr13, isr14, isr15
	.quad	isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
	.quad	isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31
	.quad	isr32, isr33, isr34, isr35, isr36, isr37, isr38, isr39
	.quad	isr40, isr41, isr42, isr43, isr44, isr45, isr46, isr47
