/*
 * Architecture primitives the portable kernel calls: the test-and-set
 * lock, barriers, the scheduler's labels, and the FP register file.
 */

	.section ".text"

/*
 * ulong _tas(ulong *key): set *key and return what it was, 0 meaning
 * the caller now holds it. amoswap with acquire ordering is the
 * lock-acquire idiom; unlock is coherence() then a plain store of 0.
 */
	.global	_tas
_tas:
	li	t0, 1
	amoswap.d.aq	a0, t0, (a0)
	ret

/* a full barrier: nothing crosses it in either direction */
	.global	coherence
coherence:
	fence	rw, rw
	ret

/* ulong ainc(ulong*): atomic increment, returning the new value */
	.global	ainc
ainc:
	li	t0, 1
	amoadd.d.aqrl	t1, t0, (a0)
	addi	a0, t1, 1
	ret

/* this hart's instruction stream sees its own earlier stores */
	.global	fencei
fencei:
	fence.i
	ret

/*
 * Cache maintenance for DMA. RISC-V caches are coherent with the
 * interconnect on QEMU and on the PolarFire's L2; ordering is all a
 * device needs from us, so these are barriers. A part with incoherent
 * DMA needs the Zicbom instructions here instead.
 */
	.global	cachedwbse
cachedwbse:
	.global	cachedwbinvse
cachedwbinvse:
	fence	rw, rw
	ret

	.global	idlewfi
idlewfi:
	wfi
	ret

/*
 * int setlabel(Label*): save sp, the return address and s0-s11; return
 * 0. gotolabel(Label*) restores them and returns 1 from the setlabel
 * that saved them. Order matches Label in dat.h.
 */
	.global	setlabel
setlabel:
	sd	sp, 0(a0)
	sd	ra, 8(a0)
	sd	s0, 16(a0)
	sd	s1, 24(a0)
	sd	s2, 32(a0)
	sd	s3, 40(a0)
	sd	s4, 48(a0)
	sd	s5, 56(a0)
	sd	s6, 64(a0)
	sd	s7, 72(a0)
	sd	s8, 80(a0)
	sd	s9, 88(a0)
	sd	s10, 96(a0)
	sd	s11, 104(a0)
	li	a0, 0
	ret

	.global	gotolabel
gotolabel:
	ld	s0, 16(a0)
	ld	s1, 24(a0)
	ld	s2, 32(a0)
	ld	s3, 40(a0)
	ld	s4, 48(a0)
	ld	s5, 56(a0)
	ld	s6, 64(a0)
	ld	s7, 72(a0)
	ld	s8, 80(a0)
	ld	s9, 88(a0)
	ld	s10, 96(a0)
	ld	s11, 104(a0)
	ld	ra, 8(a0)
	ld	sp, 0(a0)
	li	a0, 1
	ret

/* round to nearest, flags clear */
	.global	fpinit
fpinit:
	fscsr	zero
	ret

/*
 * FPsave(FPenv*) / FPrestore(FPenv*): f0-f31 then fcsr at 256, the
 * layout of FPU and FPenv in dat.h.
 */
	.global	FPsave
FPsave:
	fsd	f0, 0(a0)
	fsd	f1, 8(a0)
	fsd	f2, 16(a0)
	fsd	f3, 24(a0)
	fsd	f4, 32(a0)
	fsd	f5, 40(a0)
	fsd	f6, 48(a0)
	fsd	f7, 56(a0)
	fsd	f8, 64(a0)
	fsd	f9, 72(a0)
	fsd	f10, 80(a0)
	fsd	f11, 88(a0)
	fsd	f12, 96(a0)
	fsd	f13, 104(a0)
	fsd	f14, 112(a0)
	fsd	f15, 120(a0)
	fsd	f16, 128(a0)
	fsd	f17, 136(a0)
	fsd	f18, 144(a0)
	fsd	f19, 152(a0)
	fsd	f20, 160(a0)
	fsd	f21, 168(a0)
	fsd	f22, 176(a0)
	fsd	f23, 184(a0)
	fsd	f24, 192(a0)
	fsd	f25, 200(a0)
	fsd	f26, 208(a0)
	fsd	f27, 216(a0)
	fsd	f28, 224(a0)
	fsd	f29, 232(a0)
	fsd	f30, 240(a0)
	fsd	f31, 248(a0)
	frcsr	t0
	sw	t0, 256(a0)
	ret

	.global	FPrestore
FPrestore:
	fld	f0, 0(a0)
	fld	f1, 8(a0)
	fld	f2, 16(a0)
	fld	f3, 24(a0)
	fld	f4, 32(a0)
	fld	f5, 40(a0)
	fld	f6, 48(a0)
	fld	f7, 56(a0)
	fld	f8, 64(a0)
	fld	f9, 72(a0)
	fld	f10, 80(a0)
	fld	f11, 88(a0)
	fld	f12, 96(a0)
	fld	f13, 104(a0)
	fld	f14, 112(a0)
	fld	f15, 120(a0)
	fld	f16, 128(a0)
	fld	f17, 136(a0)
	fld	f18, 144(a0)
	fld	f19, 152(a0)
	fld	f20, 160(a0)
	fld	f21, 168(a0)
	fld	f22, 176(a0)
	fld	f23, 184(a0)
	fld	f24, 192(a0)
	fld	f25, 200(a0)
	fld	f26, 208(a0)
	fld	f27, 216(a0)
	fld	f28, 224(a0)
	fld	f29, 232(a0)
	fld	f30, 240(a0)
	fld	f31, 248(a0)
	lw	t0, 256(a0)
	fscsr	t0
	ret

/*
 * uintptr getcallerpc(void*): the return address of the function that
 * called this -- its saved ra, at -8 from its frame pointer (s0). fns.h
 * makes getcallerpc a builtin for the kernel; libkern and libinterp,
 * compiled against lib9.h, call this.
 */
	.global	getcallerpc
getcallerpc:
	ld	a0, -8(s0)
	ret
