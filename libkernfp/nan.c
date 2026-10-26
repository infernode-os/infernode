#include <lib9.h>

/*
 * NaN, infinity and the tests for them, for the native kernel (the
 * hosted emulator has the C library's, lib9/isnan-posix.c).
 *
 * By the 64 bits of the double, not by two longs. This was Plan 9's
 * union { double d; long x[2]; }, which assumes a 32-bit long: x[1] the
 * high word with the exponent in it. On an LP64 kernel -- arm64,
 * riscv64 -- long is 64 bits, x[0] is the whole double and x[1] is
 * bytes past its end, so isNaN never saw a NaN, NaN() returned the
 * smallest denormal and Inf() returned 0.0. The Limbo compiler, run on
 * a board, checks math->isnan on the canonical NaN at startup and died
 * there: "fatal limbo compiler error: bad canonical NaN".
 */

enum {
	Expshift	= 52,
	Expmask		= 0x7FF,
};

#define	SIGNBIT	((uvlong)1<<63)
#define	MANT	(((uvlong)1<<Expshift) - 1)
#define	INFBITS	((uvlong)Expmask<<Expshift)

typedef union {
	double	d;
	uvlong	u;
} Dbits;

double
NaN(void)
{
	Dbits a;

	a.u = INFBITS | 1;	/* as Plan 9's: all-ones exponent, mantissa 1 */
	return a.d;
}

int
isNaN(double d)
{
	Dbits a;

	a.d = d;
	return (a.u & INFBITS) == INFBITS && (a.u & MANT) != 0;
}

double
Inf(int sign)
{
	Dbits a;

	a.u = INFBITS;
	if(sign < 0)
		a.u |= SIGNBIT;
	return a.d;
}

int
isInf(double d, int sign)
{
	Dbits a;

	a.d = d;
	if(a.u == INFBITS)
		return sign >= 0;
	if(a.u == (INFBITS|SIGNBIT))
		return sign <= 0;
	return 0;
}
