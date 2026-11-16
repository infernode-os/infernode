#include "os.h"
#include <mp.h>
#include "dat.h"

#define iseven(a)	(((a)->p[0] & 1) == 0)

// extended binary gcd
//
// For a anv b it solves, v = gcd(a,b) and finds x and y s.t.
// ax + by = v
//
// Handbook of Applied Cryptography, Menezes et al, 1997, pg 608.  
//
// Its time follows its operands at every step: it is for numbers that
// are public, or that have been blinded (rsadecrypt's r, egsign's
// k*b).  A secret is inverted mod a prime as a power (dsasign).
//
// Every working number is made first, at the length it can reach, and
// the results given room: nothing here allocates after that, so a
// raise for want of memory leaves none of the eight behind (each made
// in turn was lost when a later one, or a sum grown by a digit, was
// refused).  mpextendedgcdtry returns -1 for it; mpextendedgcd raises.
int
mpextendedgcdtry(mpint *a, mpint *b, mpint *v, mpint *x, mpint *y)
{
	mpint *u, *A, *B, *C, *D, *a0, *b0;
	int g, atop, btop;
	vlong bits;

	if(a->sign < 0 || b->sign < 0){
		mpassign(mpzero, v);
		mpassign(mpzero, y);
		mpassign(mpzero, x);
		return 0;
	}

	// zero digits above a number are not the number: a zero written
	// with digits passed these tests, and the loops below, which look
	// at the low digit, halved it for ever
	atop = a->top;
	while(atop > 0 && a->p[atop-1] == 0)
		atop--;
	btop = b->top;
	while(btop > 0 && b->p[btop-1] == 0)
		btop--;
	// the longer operand and three digits: a sum's carry, mpadd's
	// digit of room for one, and mpleft's
	bits = ((vlong)(atop > btop? atop: btop) + 3)*Dbits;
	if(bits > MAXBITS || mpreservetry(v, bits) < 0 || mpreservetry(x, bits) < 0 || mpreservetry(y, bits) < 0)
		return -1;
	if(atop == 0){
		mpassign(b, v);
		mpnorm(v);
		mpassign(mpone, y);
		mpassign(mpzero, x);
		return 0;
	}
	if(btop == 0){
		mpassign(a, v);
		mpnorm(v);
		mpassign(mpone, x);
		mpassign(mpzero, y);
		return 0;
	}

	g = 0;
	a0 = mptrynew(bits);
	b0 = mptrynew(bits);
	u = mptrynew(bits);
	A = mptrynew(bits);
	B = mptrynew(bits);
	C = mptrynew(bits);
	D = mptrynew(bits);
	if(a0 == nil || b0 == nil || u == nil || A == nil || B == nil || C == nil || D == nil){
		mpfree(a0);
		mpfree(b0);
		mpfree(u);
		mpfree(A);
		mpfree(B);
		mpfree(C);
		mpfree(D);
		return -1;
	}
	mpassign(a, a0);
	mpassign(b, b0);
	a = a0;
	b = b0;
	a->top = atop;
	b->top = btop;

	while(iseven(a) && iseven(b)){
		mpright(a, 1, a);
		mpright(b, 1, b);
		g++;
	}

	mpassign(a, u);
	mpassign(b, v);
	mpassign(mpone, A);
	mpassign(mpzero, B);
	mpassign(mpzero, C);
	mpassign(mpone, D);

	for(;;) {
//		print("%B %B %B %B %B %B\n", u, v, A, B, C, D);
		while(iseven(u)){
			mpright(u, 1, u);
			if(!iseven(A) || !iseven(B)) {
				mpadd(A, b, A);
				mpsub(B, a, B);
			}
			mpright(A, 1, A);
			mpright(B, 1, B);
		}
	
//		print("%B %B %B %B %B %B\n", u, v, A, B, C, D);
		while(iseven(v)){
			mpright(v, 1, v);
			if(!iseven(C) || !iseven(D)) {
				mpadd(C, b, C);
				mpsub(D, a, D);
			}
			mpright(C, 1, C);
			mpright(D, 1, D);
		}
	
//		print("%B %B %B %B %B %B\n", u, v, A, B, C, D);
		if(mpcmp(u, v) >= 0){
			mpsub(u, v, u);
			mpsub(A, C, A);
			mpsub(B, D, B);
		} else {
			mpsub(v, u, v);
			mpsub(C, A, C);
			mpsub(D, B, D);
		}

		if(u->top == 0)
			break;

	}
	mpassign(C, x);
	mpassign(D, y);
	mpleft(v, g, v);

	mpfree(A);
	mpfree(B);
	mpfree(C);
	mpfree(D);
	mpfree(u);
	mpfree(a);
	mpfree(b);
	return 0;
}

void
mpextendedgcd(mpint *a, mpint *b, mpint *v, mpint *x, mpint *y)
{
	if(mpextendedgcdtry(a, b, v, x, y) < 0)
		sysfatal("mpextendedgcd: no memory");
}
