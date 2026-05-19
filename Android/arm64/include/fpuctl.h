/*
 * Linux arm64 fpu support
 * Mimic Plan9 floating point support
 * Note: FPdbleword is defined in lib9.h
 */

#include <fenv.h>

static void
setfcr(ulong fcr)
{
	/* arm64 uses FPCR register - Linux handles via fenv */
	(void)fcr;
}

static ulong
getfcr(void)
{
	ulong fcr = 0;
	return fcr;
}

static ulong
getfsr(void)
{
	ulong fsr = 0;
	return fsr;
}

static void
setfsr(ulong fsr)
{
	(void)fsr;
}

/* FCR */
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
/* FSR */
#define	FPAINEX	FPINEX
#define	FPAOVFL	FPOVFL
#define	FPAUNFL	FPUNFL
#define	FPAZDIV	FPZDIV
#define	FPAINVAL	FPINVAL
