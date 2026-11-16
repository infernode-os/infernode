#include "os.h"
#include <mp.h>
#include "dat.h"

// res = b >> shift
void
mpright(mpint *b, int shift, mpint *res)
{
	int d, l, r, i;
	mpdigit this, last;

	res->sign = b->sign;
	if(b->top==0){
		res->top = 0;
		res->sign = 1;
		return;
	}

	// a negative right shift is a left shift
	if(shift < 0){
		mpleft(b, (uint)shift == ~(~0U>>1)? (int)(~0U>>1): -shift, res);
		return;
	}

	// (no room for a shift past the number's own bits, which leaves
	// nothing: the difference was negative)
	if(res != b && shift < b->top*Dbits)
		mpbits(res, b->top*Dbits - shift);
	d = shift/Dbits;
	r = shift - d*Dbits;
	l = Dbits - r;

	//  shift all the bits out == zero, which has no sign: a negative
	//  number shifted to nothing was a zero less than zero, equal to
	//  no other and printed "-0"
	if(d>=b->top){
		res->top = 0;
		res->sign = 1;
		return;
	}

	// special case digit shifts
	if(r == 0){
		for(i = 0; i < b->top-d; i++)
			res->p[i] = b->p[i+d];
	} else {
		last = b->p[d];
		for(i = 0; i < b->top-d-1; i++){
			this = b->p[i+d+1];
			res->p[i] = (this<<l) | (last>>r);
			last = this;
		}
		res->p[i++] = last>>r;
	}
	while(i > 0 && res->p[i-1] == 0)
		i--;
	res->top = i;
	if(i==0)
		res->sign = 1;
}
