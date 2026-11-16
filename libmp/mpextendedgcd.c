#include "os.h"
#include <mp.h>

#define iseven(a)	(((a)->p[0] & 1) == 0)

// extended binary gcd
//
// For a anv b it solves, v = gcd(a,b) and finds x and y s.t.
// ax + by = v
//
// Handbook of Applied Cryptography, Menezes et al, 1997, pg 608.  
void
mpextendedgcd(mpint *a, mpint *b, mpint *v, mpint *x, mpint *y)
{
	mpint *u, *A, *B, *C, *D;
	int g, atop, btop;

	if(a->sign < 0 || b->sign < 0){
		mpassign(mpzero, v);
		mpassign(mpzero, y);
		mpassign(mpzero, x);
		return;
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
	if(atop == 0){
		mpassign(b, v);
		mpnorm(v);
		mpassign(mpone, y);
		mpassign(mpzero, x);
		return;
	}
	if(btop == 0){
		mpassign(a, v);
		mpnorm(v);
		mpassign(mpone, x);
		mpassign(mpzero, y);
		return;
	}

	g = 0;
	a = mpcopy(a);
	b = mpcopy(b);
	a->top = atop;
	b->top = btop;

	while(iseven(a) && iseven(b)){
		mpright(a, 1, a);
		mpright(b, 1, b);
		g++;
	}

	u = mpcopy(a);
	mpassign(b, v);
	A = mpcopy(mpone);
	B = mpcopy(mpzero);
	C = mpcopy(mpzero);
	D = mpcopy(mpone);

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
}
