#include "os.h"
#include <mp.h>
#include "dat.h"

// division ala knuth, seminumerical algorithms, pp 237-238
// the numbers are stored backwards to what knuth expects so j
// counts down rather than up.

void
mpdiv(mpint *dividend, mpint *divisor, mpint *quotient, mpint *remainder)
{
	int j, s, vn, sign, qsign, rsign;
	mpdigit qd, *up, *vp, *qp;
	mpint *u, *v, *t;

	// one number cannot be both results: the second written won, the
	// quotient or the remainder by the path taken
	if(quotient != nil && quotient == remainder)
		sysfatal("mpdiv: quotient and remainder are one number");

	// the results' signs, from the operands before either may have
	// been written as a result.  The quotient's was only ever set to
	// -1 (6/3 into a number that had held -5 was -2), and a quotient
	// written over the dividend gave its sign to the remainder
	qsign = dividend->sign == divisor->sign? 1: -1;
	rsign = dividend->sign;

	// divide bv zero, however the zero is written.  only top was
	// looked at, and a divisor whose top digit is zero (a number made
	// from bytes and not normalized) went on to D1, which shifts that
	// digit left until its high bit is set: for ever
	vn = divisor->top;
	while(vn > 0 && divisor->p[vn-1] == 0)
		vn--;
	if(vn == 0)
		sysfatal("mpdiv: divide by zero");
	if(vn != divisor->top){
		// zero digits above a number: divide by the number
		v = mpcopy(divisor);
		v->top = vn;
		mpdiv(dividend, v, quotient, remainder);
		mpfree(v);
		return;
	}

	// room in the results before anything is made: see mpreserve
	if(quotient != nil)
		mpreserve(quotient, mpsizebits((vlong)dividend->top+2, 0, "mpdiv"));
	if(remainder != nil)
		mpreserve(remainder, mpsizebits((vlong)dividend->top+2, 0, "mpdiv"));

	// quick check
	if(mpmagcmp(dividend, divisor) < 0){
		if(remainder != nil)
			mpassign(dividend, remainder);
		if(quotient != nil)
			mpassign(mpzero, quotient);
		return;
	}

	// D1: shift until divisor, v, has hi bit set (needed to make trial
	//     divisor accurate)
	qd = divisor->p[divisor->top-1];
	for(s = 0; (qd & mpdighi) == 0; s++)
		qd <<= 1;
	// the three working numbers together, each with all the room it
	// will use, or none of them (a raise for the second lost the first)
	u = mptrynew(mpsizebits((vlong)dividend->top+2, s, "mpdiv"));
	v = divisor;
	if(!(s == 0 && divisor != quotient && divisor != remainder))
		v = mptrynew((divisor->top+1)*Dbits);
	t = mptrynew(4*Dbits);	// storage for multiplies
	if(u == nil || v == nil || t == nil){
		mpfree(u);
		if(v != divisor)
			mpfree(v);
		mpfree(t);
		sysfatal("mpdiv: no memory");
	}
	if(v == divisor)
		mpassign(dividend, u);
	else{
		mpleft(dividend, s, u);
		mpleft(divisor, s, v);
	}
	up = u->p+u->top-1;
	vp = v->p+v->top-1;
	vn = v->top;

	// D1a: make sure high digit of dividend is less than high digit of divisor
	if(*up >= *vp){
		*++up = 0;
		u->top++;
	}

	qp = nil;
	if(quotient != nil){
		mpbits(quotient, (u->top - v->top)*Dbits);
		quotient->top = u->top - v->top;
		qp = quotient->p+quotient->top-1;
	}

	// D2, D7: loop on length of dividend
	for(j = u->top; j > vn; j--){

		// D3: calculate trial divisor
		mpdigdiv(up-1, *vp, &qd);

		// D3a: rule out trial divisors 2 greater than real divisor
		if(vn > 1) for(;;){
			memset(t->p, 0, 3*Dbytes);	// mpvecdigmuladd adds to what's there
			mpvecdigmuladd(vp-1, 2, qd, t->p);
			if(mpveccmp(t->p, 3, up-2, 3) > 0)
				qd--;
			else
				break;
		}

		// D4: u -= v*qd << j*Dbits
		sign = mpvecdigmulsub(v->p, vn, qd, up-vn);
		if(sign < 0){

			// D6: trial divisor was too high, add back borrowed
			//     value and decrease divisor
			mpvecadd(up-vn, vn+1, v->p, vn, up-vn);
			qd--;
		}

		// D5: save quotient digit
		if(qp != nil)
			*qp-- = qd;

		// push top of u down one
		u->top--;
		*up-- = 0;
	}
	if(qp != nil){
		mpnorm(quotient);
		if(quotient->top != 0)
			quotient->sign = qsign;
	}

	if(remainder != nil){
		mpright(u, s, remainder);	// u is the remainder shifted
		// a remainder of nothing has no sign: with a negative dividend
		// it was a zero less than zero, to which mpmod then added the
		// modulus (-6 mod 3 was 3)
		if(remainder->top != 0)
			remainder->sign = rsign;
		else
			remainder->sign = 1;
	}

	mpfree(t);
	mpfree(u);
	if(v != divisor)
		mpfree(v);
}
