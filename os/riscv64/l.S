/*
 * RISC-V S-mode entry, under SBI firmware (OpenSBI on QEMU, the Hart
 * Software Services' OpenSBI on a PolarFire SoC).
 *
 * The SBI boot protocol: one hart -- whichever won the firmware's
 * lottery, not necessarily hart 0 -- arrives at _start in S-mode with
 * a0 = its hart id and a1 = the device tree, paging off (satp Bare),
 * interrupts off. The others stay in the firmware until the kernel
 * asks for them with SBI's hart_start (launchsmp), which brings each
 * to secentry with a0 = its hart id and a1 = the opaque word we gave
 * it: the address of its smpboot slot.
 *
 * Unlike ../arm64/l.S there is no exception level to drop from and no
 * core to park. There is also no free memory below the image -- the
 * firmware lives there -- so the boot stack is in .bss (trap.c knows).
 */

#define	SSTATUS_FS_INITIAL	(1<<13)

	.section ".text.boot", "ax"
	.global	_start
_start:
	/*
	 * The RISC-V Linux Image header, 64 bytes, so a boot loader that
	 * boots Linux boots this: U-Boot's booti checks magic2 and takes
	 * the size from here. That is the BeagleV-Fire's shipped chain --
	 * the HSS's OpenSBI, then U-Boot in S-mode, then "Linux" -- and
	 * the kernel's entry contract is already Linux's (hart id in a0,
	 * device tree in a1, S-mode, paging off). This kernel is linked at
	 * a fixed address and not relocatable, so it must be loaded at
	 * that address (the board's kernel.ld); booti runs an Image where
	 * it was loaded.
	 *
	 * The first word is a jump over the rest (uncompressed, so it is
	 * the whole of code0).
	 */
	.option	push
	.option	norvc
	j	realstart		/* code0 */
	.option	pop
	.word	0			/* code1 */
	.dword	0x200000		/* text_offset: 2MB above RAM, like Linux */
	.dword	end - _start		/* image_size, .bss and all */
	.dword	0			/* flags: little-endian */
	.word	2			/* header version 0.2 */
	.word	0
	.dword	0
	.ascii	"RISCV\0\0\0"		/* magic, deprecated */
	.ascii	"RSC\x05"		/* magic2 */
	.word	0			/* no PE/COFF header */

realstart:
	/*
	 * a0 and a1 are the only record of which hart this is and where
	 * the tree is. Park them in callee-saved registers until .bss is
	 * clear, then store them.
	 */
	mv	s0, a0
	mv	s1, a1

	csrw	sie, zero

	/*
	 * The hart lottery, as Linux's head.S has it. The SBI boot protocol
	 * brings one hart here, but a U-Boot built with CONFIG_SMP sends
	 * every hart to the image it boots at once (arch/riscv/lib/bootm.c,
	 * smp_call_function), and four harts clearing .bss and running kmain
	 * on top of one another is not a boot. The first to increment
	 * hartlottery is the boot hart; any other gives itself back to the
	 * firmware (SBI HSM hart_stop), stopped, so that launchsmp can start
	 * it at secentry like any other. Firmware without HSM refuses the
	 * stop, and then the hart parks here for good.
	 *
	 * hartlottery is in .data, not .bss, because .bss is not cleared
	 * yet; the winner zeroes the stash's copy of it (below) so that an
	 * image #B reproduces starts with a fresh draw.
	 */
	la	t0, hartlottery
	li	t1, 1
	amoadd.w	t1, t1, (t0)
	bnez	t1, lostlottery
	la	sp, bootstacktop

	/*
	 * FP on (sstatus.FS = Initial). The kernel core is plain integer
	 * code, but libinterp is built with FP -- Dis has a REAL -- and
	 * with FS Off the first fld is an illegal-instruction trap.
	 */
	li	t0, SSTATUS_FS_INITIAL
	csrs	sstatus, t0

	/* zero .bss (the boot stack is in it; nothing is on it yet) */
	la	t0, __bss_start
	la	t1, __bss_end
1:
	bgeu	t0, t1, 2f
	sd	zero, 0(t0)
	addi	t0, t0, 8
	j	1b
2:
	/*
	 * Save .data as it was loaded, before anything writes to it: #B
	 * (../arm64/devboot.c) reproduces the image from .text and .rodata
	 * in place plus this copy.
	 */
	la	t0, __data_start
	la	t1, edata
	la	t2, __datastash
3:
	bgeu	t0, t1, 4f
	ld	t3, 0(t0)
	sd	t3, 0(t2)
	addi	t0, t0, 8
	addi	t2, t2, 8
	j	3b
4:
	/* the stash's hartlottery: a fresh draw for a reproduced image */
	la	t0, hartlottery
	la	t1, __data_start
	sub	t0, t0, t1
	la	t2, __datastash
	add	t0, t0, t2
	sw	zero, 0(t0)

	la	t0, dtbptr
	sd	s1, 0(t0)
	la	t0, boothartid
	sd	s0, 0(t0)

	/* hart 0's Mach, in the register the whole kernel reads m from */
	la	tp, machs

	call	kmain

	/* kmain does not return */
5:
	wfi
	j	5b

	/*
	 * A hart that lost the lottery: back to the firmware, stopped
	 * (HSM, extension "HSM", function 1, hart_stop). It does not
	 * return if the firmware has HSM.
	 */
lostlottery:
	li	a7, 0x48534D
	li	a6, 1
	ecall
6:
	wfi
	j	6b

	/*
	 * A secondary hart, started by sbihartstart(): a0 its hart id,
	 * a1 the address of its Smpboot slot (sp, mach). It has its own
	 * stack and Mach from the slot and goes straight to C.
	 */
	.global	secentry
	.align	2
secentry:
	ld	sp, 0(a1)
	ld	tp, 8(a1)
	csrw	sie, zero
	li	t0, SSTATUS_FS_INITIAL
	csrs	sstatus, t0
	call	squidboy
	j	5b

	.section ".data"
	.align	2
	.global	hartlottery
hartlottery:
	.word	0

	.section ".bss"
	.align	4
	.global	bootstack
bootstack:
	.space	32768
	.global	bootstacktop
bootstacktop:
