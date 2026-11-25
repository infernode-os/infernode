/*
 * A Multiboot boot loader enters an ELF64 kernel in 32-bit protected
 * mode with
 *
 *	eax = 0x2BADB002 (Multiboot boot loader magic)
 *	ebx = the Multiboot information
 *	esp = a boot stack
 *
 * and a flat GDT.  The kernel entry is therefore a 32-bit stub:
 * identity-map the first GiB with 2 MiB pages, set PAE and LME, enable
 * paging, load a 64-bit GDT, and far-jump to the C entry.  The ELF
 * class is 64-bit throughout; only the bytes at _start are 32-bit
 * machine code.
 *
 * The stub's page tables, GDT and the saved Multiboot pointer live in
 * the kernel image's own .bss, not at fixed low addresses: a Multiboot
 * loader may place the information block, its memory map and the
 * command line anywhere below 1 MiB, and the fixed pages this used to
 * occupy could destroy them.  The kernel is linked at 1 MiB, so those
 * symbols are physical addresses while paging is off; the stub zeroes
 * the block before use and addresses it through 32-bit immediates.
 *
 * Immediate operands are safe; memory operands with a symbol are not.
 * A 64-bit assembler emits PC-relative references for symbol operands
 * even under .code32, and in 32-bit execution those displacements are
 * absolute, so `lgdt symbol` would load from the wrong address.  The
 * one such instruction here is encoded by hand below.
 */

	/*
	 * Multiboot 1 header.  The magic must be within the first 8192
	 * bytes of the file, so kernel.ld places this section first, at
	 * 1 MiB, and the flat image for loaders that want one starts with
	 * it.
	 *
	 * flags bit 1 asks for mem_lower/mem_upper.  Bit 16 is
	 * MULTIBOOT_HEADER_HAS_ADDR, the a.out kludge: QEMU's Multiboot
	 * loader refuses an ELF64 image ("give a 32bit one") unless the
	 * addresses are given explicitly, and then it copies the flat
	 * image instead of parsing the ELF.  The addresses are the same
	 * whether the loader reads the ELF or the flat image, because the
	 * image is linked at 1 MiB.
	 */
#define MB_HDR_FLAGS	0x00010002
	.section .multiboot, "a"
	.align 4
	.long	0x1BADB002
	.long	MB_HDR_FLAGS
	.long	-(0x1BADB002 + MB_HDR_FLAGS)
	.long	0x100000		/* header_addr: this header */
	.long	0x100000		/* load_addr */
	.long	0			/* load_end_addr: the whole file */
	.long	__bss_end		/* bss_end_addr */
	.long	_start			/* entry_addr */

	.section .text.boot, "ax"
	.code32
	.globl _start
_start:
	cli
	cld

	/* Zero the scratch block: the loader is not required to have
	 * zeroed .bss, and a stale PML4 entry would be a wild mapping. */
	movl	$bootscratch, %edi
	xorl	%eax, %eax
	movl	$(5*4096/4), %ecx
	rep stosl

	/* remember the Multiboot information */
	movl	%ebx, bootmbi

	/* pml4[0] = pdpt | P | RW (PAE entries are 8 bytes) */
	movl	$bootpml4, %edi
	movl	$bootpdpt, %eax
	orl	$3, %eax
	movl	%eax, (%edi)
	movl	$0, 4(%edi)

	/* pdpt[0] = pd | P | RW */
	movl	$bootpdpt, %edi
	movl	$bootpd, %eax
	orl	$3, %eax
	movl	%eax, (%edi)
	movl	$0, 4(%edi)

	/* 512 2 MiB pages: the first GiB, identity mapped */
	movl	$bootpd, %edi
	movl	$0x83, %eax		/* P | RW | PS */
	xorl	%ecx, %ecx
1:
	movl	%eax, (%edi)
	movl	$0, 4(%edi)
	addl	$0x200000, %eax
	addl	$8, %edi
	incl	%ecx
	cmpl	$512, %ecx
	jne	1b

	/* the 64-bit GDT: null, code, data */
	movl	$bootgdt, %edi
	xorl	%eax, %eax
	movl	%eax, 0(%edi)
	movl	%eax, 4(%edi)
	movl	$0x0000ffff, 8(%edi)
	movl	$0x00af9a00, 12(%edi)
	movl	$0x0000ffff, 16(%edi)
	movl	$0x00af9200, 20(%edi)

	/* GDTR: limit 23, base bootgdt */
	movl	$bootgdtr, %edi
	movw	$23, 0(%edi)
	movl	$bootgdt, 2(%edi)

	/* PAE, CR3, LME, PG */
	movl	%cr4, %eax
	orl	$0x20, %eax		/* CR4.PAE */
	movl	%eax, %cr4

	movl	$bootpml4, %eax
	movl	%eax, %cr3

	movl	$0xC0000080, %ecx	/* MSR_EFER */
	rdmsr
	orl	$0x100, %eax		/* EFER.LME */
	wrmsr

	movl	%cr0, %eax
	orl	$0x80000001, %eax	/* CR0.PG | CR0.PE */
	movl	%eax, %cr0

	/* 0F 01 /2 with an absolute disp32; a symbolic operand would be
	 * assembled RIP-relative in a 64-bit object. */
	.byte	0x0f, 0x01, 0x15
	.long	bootgdtr
	ljmp	$0x08, $longmode

	.code64
longmode:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	leaq	stack_top(%rip), %rsp
	movl	$bootmbi, %eax
	movl	(%rax), %edi
	call	main

2:
	hlt
	jmp	2b

	.section .bss
	.align 4096
bootscratch:
bootpml4:	.skip	4096
bootpdpt:	.skip	4096
bootpd:		.skip	4096
bootpd2:	.skip	4096
bootaux:	.skip	4096		/* GDT, GDTR and the saved MBI pointer */
bootgdt = bootaux
bootgdtr = bootaux + 0x100
bootmbi = bootaux + 0x200

	.align 16
stack:
	.skip	16384
stack_top:
