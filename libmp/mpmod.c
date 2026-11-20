#include "os.h"
#include <mp.h>
#include "dat.h"

// remainder = b mod m
//
// knuth, vol 2, pp 398-400

//
// The remainder is the least that is not negative, whatever the signs:
// 0 <= remainder < |m|.  The modulus was added to a negative remainder
// as it stood, so a negative one took it further below zero (-7 mod -5
// was -7), and a remainder written over the modulus was added to
// itself (-3 mod 5 into the 5 was -6).

int
mpmodtry(mpint *b, mpint *m, mpint *remainder)
{
	mpint *mm;
	vlong bits;

	// room for the remainder and for the modulus less it, first
	bits = ((vlong)(b->top > m->top? b->top: m->top) + 2)*Dbits;
	if(bits > MAXBITS || mpreservetry(remainder, bits) < 0)
		return -1;
	mm = m;
	if(remainder == m && b->sign < 0){
		mm = mptrycopy(m);
		if(mm == nil)
			return -1;
	}
	if(mpdivtry(b, m, nil, remainder) < 0){
		if(mm != m)
			mpfree(mm);
		return -1;
	}
	if(remainder->sign < 0)
		mpmagsub(mm, remainder, remainder);	// |m| - |remainder|
	if(mm != m)
		mpfree(mm);
	return 0;
}

void
mpmod(mpint *b, mpint *m, mpint *remainder)
{
	mpsizebits((vlong)(b->top > m->top? b->top: m->top) + 2, Dbits, "mpmod");
	if(mpmodtry(b, m, remainder) < 0)
		sysfatal("mpmod: no memory");
}
