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

void
mpmod(mpint *b, mpint *m, mpint *remainder)
{
	mpint *mm;

	mm = m;
	if(remainder == m && b->sign < 0)
		mm = mpcopy(m);
	mpdiv(b, m, nil, remainder);
	if(remainder->sign < 0)
		mpmagsub(mm, remainder, remainder);	// |m| - |remainder|
	if(mm != m)
		mpfree(mm);
}
