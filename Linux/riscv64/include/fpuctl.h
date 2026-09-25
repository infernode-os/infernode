/*
 * Linux riscv64 fpu support
 * Mimic Plan9 floating point support
 * Note: FPdbleword is defined in lib9.h
 *
 * RISC-V has no floating-point traps: fcsr holds only the rounding
 * mode (frm, bits 7:5) and the sticky exception flags (fflags, bits
 * 4:0).  So the FCR's exception-enable bits cannot be honoured and
 * getfcr reports none enabled; the rounding mode and the status flags
 * are real.  The bit values below are fcsr's own, so no translation
 * is needed beyond the shift.
 */

static void
setfcr(ulong fcr)
{
	ulong frm;

	frm = (fcr>>5) & 7;
	__asm__ volatile("fsrm %0" : : "r"(frm));
}

static ulong
getfcr(void)
{
	ulong frm;

	__asm__ volatile("frrm %0" : "=r"(frm));
	return (frm & 7) << 5;
}

static ulong
getfsr(void)
{
	ulong fflags;

	__asm__ volatile("frflags %0" : "=r"(fflags));
	return fflags & 0x1F;
}

static void
setfsr(ulong fsr)
{
	__asm__ volatile("fsflags %0" : : "r"(fsr & 0x1F));
}

/* FCR: the exception bits (enables) are fcsr's fflags positions, unenforced */
#define	FPINEX	(1<<0)	/* NX */
#define	FPUNFL	(1<<1)	/* UF */
#define	FPOVFL	(1<<2)	/* OF */
#define	FPZDIV	(1<<3)	/* DZ */
#define	FPINVAL	(1<<4)	/* NV */
/* rounding: frm << 5 */
#define	FPRNR	(0<<5)	/* RNE */
#define	FPRZ	(1<<5)	/* RTZ */
#define	FPRNINF	(2<<5)	/* RDN */
#define	FPRPINF	(3<<5)	/* RUP */
#define	FPRMASK	(7<<5)
/* no precision control: doubles are doubles */
#define	FPPEXT	0
#define	FPPSGL	0
#define	FPPDBL	0
#define	FPPMASK	0
/* FSR */
#define	FPAINEX	FPINEX
#define	FPAOVFL	FPOVFL
#define	FPAUNFL	FPUNFL
#define	FPAZDIV	FPZDIV
#define	FPAINVAL	FPINVAL
