#include "os.h"
#include <mp.h>
#include "dat.h"

// res = b << shift
void
mpleft(mpint *b, int shift, mpint *res)
{
	int d, l, r, i, otop;
	mpdigit this, last;

	res->sign = b->sign;
	if(b->top==0){
		res->top = 0;
		return;
	}

	// a negative left shift is a right shift
	// (the most negative int is its own negative: it came back here from
	// mpright, and went there again, without end; asked of its bits, as a
	// compiler may take shift == -shift to be true of 0 alone)
	if(shift < 0){
		mpright(b, (uint)shift == ~(~0U>>1)? (int)(~0U>>1): -shift, res);
		return;
	}

	// b and res may be the same so remember the old top
	otop = b->top;

	// the sum below is an int: wrapped, no room was made for the
	// digits and they were stored anyway
	if(shift > (int)(~0U>>1) - otop*Dbits)
		sysfatal("mpleft: shift of %d bits is too large", shift);

	// shift
	mpbits(res, otop*Dbits + shift);	// overkill
	res->top = DIGITS(otop*Dbits + shift);
	d = shift/Dbits;
	l = shift - d*Dbits;
	r = Dbits - l;

	if(l == 0){
		for(i = otop-1; i >= 0; i--)
			res->p[i+d] = b->p[i];
	} else {
		last = 0;
		for(i = otop-1; i >= 0; i--) {
			this = b->p[i];
			res->p[i+d+1] = (last<<l) | (this>>r);
			last = this;
		}
		res->p[d] = last<<l;
	}
	for(i = 0; i < d; i++)
		res->p[i] = 0;

	// normalize
	while(res->top > 0 && res->p[res->top-1] == 0)
		res->top--;
}
