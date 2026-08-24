/*
 * AArch64 reset entry for BCM2837 (Raspberry Pi 3B+).
 *
 * All four Cortex-A53 cores are released at the kernel load address by
 * the VideoCore firmware, so the first job is to park cores 1-3 and let
 * core 0 alone proceed.  The parked cores sit in wfe; bringing them up
 * later means writing an entry address to their mailbox and issuing sev.
 *
 * The firmware enters at EL2, so we drop to EL1 before running any C.
 * Doing it here rather than later keeps every C function in the kernel
 * at one known exception level.
 *
 * x0 carries a flattened device tree pointer under both boot
 * protocols this tree targets -- QEMU's Linux arm64 one and the
 * Raspberry Pi firmware's.  It is saved to dtbptr for ../arm64/fdt.c.
 *
 * Note: do not assume the PC at entry.  QEMU's raspi3b starts execution
 * at 0x0 behind a small firmware shim that branches to the load address,
 * whereas real hardware enters directly.  Everything here is written
 * position-independently or via the linker-supplied symbols.
 */

/*
 * SCTLR_EL1 with the RES1 bits set and everything else off: MMU
 * disabled, caches disabled, little-endian.  A known starting state
 * matters more than a fast one until the MMU is up.
 */
#define SCTLRRES1	0x30D00800

/* SPSR to eret with: EL1h (use SP_EL1), all of DAIF masked */
#define SPSREL1H	0x3C5

.section ".text.boot"
.global _start

_start:
	/*
	 * x0 holds a device tree pointer, and this is the only moment it
	 * survives: x0 is the first register anything reaches for. Park
	 * it in a callee-saved register now and store it once .bss has
	 * been cleared -- storing it before the clear would zero it.
	 * x19 survives the eret below; eret changes exception level, not
	 * general registers.
	 */
	mov	x19, x0

	mrs	x0, mpidr_el1
	and	x0, x0, #3
	cbz	x0, core0

	/* cores 1-3: park until woken */
park:
	wfe
	b	park

core0:
	/*
	 * Stack grows down from the kernel load address, into the
	 * memory below _start which the firmware leaves free.
	 */
	ldr	x0, =_start
	mov	sp, x0

	/* already at EL1?  then there is nothing to drop. */
	mrs	x0, CurrentEL
	lsr	x0, x0, #2
	cmp	x0, #1
	b.eq	atel1

	/*
	 * At EL2.  Let EL1 use the physical counter and timer, and zero
	 * the virtual offset so virtual and physical time agree.
	 */
	mrs	x0, cnthctl_el2
	orr	x0, x0, #3		/* EL1PCTEN | EL1PCEN */
	msr	cnthctl_el2, x0
	msr	cntvoff_el2, xzr

	/* EL1 executes AArch64 (HCR_EL2.RW, bit 31) */
	mov	x0, #1
	lsl	x0, x0, #31
	msr	hcr_el2, x0

	/* give EL1 a known control register */
	ldr	x0, =SCTLRRES1
	msr	sctlr_el1, x0

	/* eret into atel1, at EL1h, interrupts masked */
	mov	x0, #SPSREL1H
	msr	spsr_el2, x0
	adr	x0, atel1
	msr	elr_el2, x0
	ldr	x0, =_start
	msr	sp_el1, x0
	eret

atel1:
	/* re-establish the stack: SP_EL1 selection may have changed it */
	ldr	x0, =_start
	mov	sp, x0

	/*
	 * Let EL0 and EL1 touch FP/SIMD (CPACR_EL1.FPEN = 0b11).  The
	 * kernel is built -mgeneral-regs-only and does not need it, but
	 * leaving it trapped would turn any future FP use into a baffling
	 * exception rather than working code.
	 */
	mov	x0, #(3 << 20)
	msr	cpacr_el1, x0
	isb

	/* zero .bss */
	ldr	x1, =__bss_start
	ldr	x2, =__bss_end
clrbss:
	cmp	x1, x2
	b.ge	callmain
	str	xzr, [x1], #8
	b	clrbss

callmain:
	/* .bss is clear, so the device tree pointer can be recorded */
	ldr	x0, =dtbptr
	str	x19, [x0]

	bl	kmain

	/* kmain must not return; park if it does */
	b	park
