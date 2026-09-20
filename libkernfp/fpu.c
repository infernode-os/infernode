/*
 * The floating point the kernel itself has to provide: sqrt, and the
 * two control registers.
 *
 * $Math is a thin module -- libinterp/math.c is mostly argument
 * shuffling in front of Sun's fdlibm -- but the pieces underneath it
 * that every HOSTED port takes from the host are missing on bare
 * metal, and there are exactly three of them:
 *
 *	sqrt		fdlibm ships e_sqrt.c, which defines
 *			__ieee754_sqrt, but no w_sqrt.c wrapper to give
 *			it the plain name. Hosted ports get the plain
 *			name from the host's libm.
 *
 *	getfcr/setfcr	the rounding mode and exception enables.
 *	getfsr/setfsr	the accrued exception flags.
 *			Hosted ports get these from <fenv.h> or from the
 *			platform's fpuctl.h. libmath/FPcontrol-Inferno.c
 *			is written against them.
 *
 * WHY THIS DIRECTORY AND NOT os/arm64. Two reasons, and both are the
 * compiler flags rather than taste. os/arm64 is compiled
 * -mgeneral-regs-only, so a double cannot be NAMED there -- which
 * rules out sqrt -- and the assembler with that flag does not know the
 * names FPCR and FPSR either, so even the accessors, which move them
 * through a general register and never touch a floating point value,
 * fail to assemble. libkernfp exists precisely for kernel code that
 * needs hardware floating point, and is compiled with it available.
 *
 * The AArch64 arms are guarded rather than assumed. Another board
 * bringing up another architecture gets fdlibm's sqrt and a pair of
 * accessors that report a machine with no exceptions pending, which is
 * wrong but harmless, and the compiler will not silently produce
 * something that looks like it works.
 */

#include "lib9.h"

extern double __ieee754_sqrt(double);

/*
 * On AArch64 sqrt is one instruction, and fsqrt is correctly rounded
 * by the architecture -- so this is not an approximation of fdlibm's
 * answer, it is the same answer, against several hundred lines of
 * integer arithmetic written for machines that had no such
 * instruction.
 *
 * Inline asm rather than __builtin_sqrt: the builtin is entitled to
 * compile into a call to sqrt, and a sqrt that calls itself is a stack
 * overflow rather than a number.
 */
double
sqrt(double x)
{
#ifdef __aarch64__
	double r;

	__asm__ volatile("fsqrt %d0, %d1" : "=w"(r) : "w"(x));
	return r;
#else
	return __ieee754_sqrt(x);
#endif
}

/*
 * FPCR holds the rounding mode and the exception enables; FPSR holds
 * the accrued exception flags. Inferno/arm64/include/u.h already
 * defines Plan 9's bit names against the AArch64 layout, so nothing
 * here has to translate: FPRNR really is (0<<22) and FPAINVAL really
 * is (1<<0).
 *
 * Both registers are 32 bits, moved as 64-bit values because that is
 * the only width mrs and msr have.
 */
ulong
getfcr(void)
{
#ifdef __aarch64__
	uvlong v;

	__asm__ volatile("mrs %0, fpcr" : "=r"(v));
	return (ulong)v;
#else
	return 0;
#endif
}

void
setfcr(ulong fcr)
{
#ifdef __aarch64__
	uvlong v;

	v = fcr;
	__asm__ volatile("msr fpcr, %0" : : "r"(v));
#else
	USED(fcr);
#endif
}

ulong
getfsr(void)
{
#ifdef __aarch64__
	uvlong v;

	__asm__ volatile("mrs %0, fpsr" : "=r"(v));
	return (ulong)v;
#else
	return 0;
#endif
}

void
setfsr(ulong fsr)
{
#ifdef __aarch64__
	uvlong v;

	v = fsr;
	__asm__ volatile("msr fpsr, %0" : : "r"(v));
#else
	USED(fsr);
#endif
}
