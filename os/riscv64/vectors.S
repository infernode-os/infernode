/*
 * The trap vector: every exception and interrupt taken in S-mode.
 *
 * stvec in direct mode points here. Build a Ureg on the current stack
 * (the kernel has no user mode, so the stack is always a kernel one),
 * call trap(Ureg*), put it all back and sret.
 *
 * tp is saved and NOT restored. tp is the per-hart Mach pointer
 * (dat.h), and trap() may reschedule: the process that took this trap
 * can resume on another hart, and must come back holding that hart's
 * Mach, which tp already holds there. Restoring the saved one would
 * hand it the hart it left. (../arm64/vectors.S skips x28 for the same
 * reason.)
 */

#include "ureg.h"

#define	R(n)	((n)*8)
#define	OPC	256
#define	OSTATUS	264
#define	OCAUSE	272
#define	OTVAL	280
#define	OSP	288

	.section ".text"
	.align	4
	.global	trapvec
trapvec:
	addi	sp, sp, -UREGSIZE
	sd	x1, R(1)(sp)
	sd	x3, R(3)(sp)
	sd	x4, R(4)(sp)
	sd	x5, R(5)(sp)
	sd	x6, R(6)(sp)
	sd	x7, R(7)(sp)
	sd	x8, R(8)(sp)
	sd	x9, R(9)(sp)
	sd	x10, R(10)(sp)
	sd	x11, R(11)(sp)
	sd	x12, R(12)(sp)
	sd	x13, R(13)(sp)
	sd	x14, R(14)(sp)
	sd	x15, R(15)(sp)
	sd	x16, R(16)(sp)
	sd	x17, R(17)(sp)
	sd	x18, R(18)(sp)
	sd	x19, R(19)(sp)
	sd	x20, R(20)(sp)
	sd	x21, R(21)(sp)
	sd	x22, R(22)(sp)
	sd	x23, R(23)(sp)
	sd	x24, R(24)(sp)
	sd	x25, R(25)(sp)
	sd	x26, R(26)(sp)
	sd	x27, R(27)(sp)
	sd	x28, R(28)(sp)
	sd	x29, R(29)(sp)
	sd	x30, R(30)(sp)
	sd	x31, R(31)(sp)
	addi	t0, sp, UREGSIZE
	sd	t0, R(2)(sp)
	sd	t0, OSP(sp)
	csrr	t0, sepc
	sd	t0, OPC(sp)
	csrr	t0, sstatus
	sd	t0, OSTATUS(sp)
	csrr	t0, scause
	sd	t0, OCAUSE(sp)
	csrr	t0, stval
	sd	t0, OTVAL(sp)

	mv	a0, sp
	call	trap

	.global	trapreturn
trapreturn:
	ld	t0, OPC(sp)
	csrw	sepc, t0
	ld	t0, OSTATUS(sp)
	csrw	sstatus, t0
	ld	x1, R(1)(sp)
	ld	x3, R(3)(sp)
	/* x4 (tp): see above */
	ld	x5, R(5)(sp)
	ld	x6, R(6)(sp)
	ld	x7, R(7)(sp)
	ld	x8, R(8)(sp)
	ld	x9, R(9)(sp)
	ld	x10, R(10)(sp)
	ld	x11, R(11)(sp)
	ld	x12, R(12)(sp)
	ld	x13, R(13)(sp)
	ld	x14, R(14)(sp)
	ld	x15, R(15)(sp)
	ld	x16, R(16)(sp)
	ld	x17, R(17)(sp)
	ld	x18, R(18)(sp)
	ld	x19, R(19)(sp)
	ld	x20, R(20)(sp)
	ld	x21, R(21)(sp)
	ld	x22, R(22)(sp)
	ld	x23, R(23)(sp)
	ld	x24, R(24)(sp)
	ld	x25, R(25)(sp)
	ld	x26, R(26)(sp)
	ld	x27, R(27)(sp)
	ld	x28, R(28)(sp)
	ld	x29, R(29)(sp)
	ld	x30, R(30)(sp)
	ld	x31, R(31)(sp)
	addi	sp, sp, UREGSIZE
	sret

	.global	trapinit
trapinit:
	la	t0, trapvec
	csrw	stvec, t0
	ret
