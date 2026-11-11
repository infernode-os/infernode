/*
 * The EL2 half of probe.c: a vector table that reports a fault and steps
 * over it, the PSCI call, and where a started core arrives.
 */

	.text

/* void setvbar(void) */
	.global	setvbar
setvbar:
	adr	x0, vectors
	msr	vbar_el2, x0
	isb
	ret

/* u64int smc(u64int fn, u64int a1, u64int a2, u64int a3) */
	.global	smc
smc:
	smc	#0
	ret

/*
 * Where PSCI CPU_ON lands a core: MMU off, no stack. Records its MPIDR
 * and exception level and turns itself off again.
 */
	.global	coreentry
coreentry:
	mrs	x1, mpidr_el1
	ubfx	x2, x1, #8, #8		/* the core number is Aff1 on an A76 */
	ldr	x3, =coreel
	mrs	x4, CurrentEL
	str	x4, [x3, x2, lsl #3]
	ldr	x3, =coreflag
	str	x1, [x3, x2, lsl #3]
	dsb	sy
	ldr	x0, =0x84000002		/* CPU_OFF */
	smc	#0
1:
	wfe
	b	1b

	.macro	vent
	.balign	0x80
	b	fault
	.endm

	.balign	0x800
vectors:
	.rept	16
	vent
	.endr

fault:
	stp	x29, x30, [sp, #-16]!
	stp	x0, x1, [sp, #-16]!
	stp	x2, x3, [sp, #-16]!
	stp	x4, x5, [sp, #-16]!
	stp	x6, x7, [sp, #-16]!
	stp	x8, x9, [sp, #-16]!
	stp	x10, x11, [sp, #-16]!
	stp	x12, x13, [sp, #-16]!
	stp	x14, x15, [sp, #-16]!
	stp	x16, x17, [sp, #-16]!
	stp	x18, x19, [sp, #-16]!
	mrs	x0, esr_el2
	mrs	x1, elr_el2
	mrs	x2, far_el2
	bl	excn
	mrs	x0, elr_el2
	add	x0, x0, #4
	msr	elr_el2, x0
	ldp	x18, x19, [sp], #16
	ldp	x16, x17, [sp], #16
	ldp	x14, x15, [sp], #16
	ldp	x12, x13, [sp], #16
	ldp	x10, x11, [sp], #16
	ldp	x8, x9, [sp], #16
	ldp	x6, x7, [sp], #16
	ldp	x4, x5, [sp], #16
	ldp	x2, x3, [sp], #16
	ldp	x0, x1, [sp], #16
	ldp	x29, x30, [sp], #16
	eret
