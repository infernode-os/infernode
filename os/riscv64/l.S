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

	.section ".bss"
	.align	4
	.global	bootstack
bootstack:
	.space	32768
	.global	bootstacktop
bootstacktop:
