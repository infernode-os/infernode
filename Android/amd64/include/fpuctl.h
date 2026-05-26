/*
 * Android x86_64 fpu support — Bionic libc + x86_64 ABI.
 * Counterpart to Android/arm64/include/fpuctl.h, but x86 instead of arm.
 *
 * The instruction set is identical to Linux/amd64 x86_64; the only
 * difference between glibc and Bionic is in libc-level wrappers we
 * don't touch here, so reuse the same inline-asm controls.
 * Inferno doesn't actually need precise FP-control on Android — these
 * are kept for API symmetry with the desktop builds and to satisfy
 * lib9.h's expectations.
 */
static void
setfcr(ulong fcr)
{
	unsigned short cw = (unsigned short)(fcr ^ 0x3f);
	__asm__ volatile (
		"fldcw %0"
		: /* no output */
		: "m" (cw)
	);
}

static ulong
getfcr(void)
{
	unsigned short cw;
	__asm__ volatile (
		"fstcw %0"
		: "=m" (cw)
	);
	return (ulong)(cw ^ 0x3f);
}

static ulong
getfsr(void)
{
	unsigned short sw;
	__asm__ volatile (
		"fstsw %0"
		: "=m" (sw)
	);
	return (ulong)sw;
}

static void
setfsr(ulong fsr)
{
	(void)fsr;
	__asm__ volatile ("fclex");
}

/* FCR - FPU Control Register bits */
#define	FPINEX	(1<<5)
#define	FPUNFL	((1<<4)|(1<<1))
#define	FPOVFL	(1<<3)
#define	FPZDIV	(1<<2)
#define	FPINVAL	(1<<0)
#define	FPRNR	(0<<10)
#define	FPRZ	(3<<10)
#define	FPRPINF	(2<<10)
#define	FPRNINF	(1<<10)
#define	FPRMASK	(3<<10)
#define	FPPEXT	(3<<8)
#define	FPPSGL	(0<<8)
#define	FPPDBL	(2<<8)
#define	FPPMASK	(3<<8)

/* FSR - FPU Status Register bits (same as FCR for exceptions) */
#define	FPAINEX	FPINEX
#define	FPAOVFL	FPOVFL
#define	FPAUNFL	FPUNFL
#define	FPAZDIV	FPZDIV
#define	FPAINVAL	FPINVAL
