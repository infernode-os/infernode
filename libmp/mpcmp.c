#include "os.h"
#include <mp.h>
#include "dat.h"

// The comparisons here and in mpveccmp.c stop at the first digit that
// differs, and take longer the more two numbers have in common.  They
// are for public numbers.  Where one is a secret the caller has seen
// to it: a nonce's range is checked on its bytes with every byte
// looked at (libsec/mpnonce.c), the private arithmetic is mpexp's,
// mpexpcrt's and mpmuladdmod's, which compare nothing, and what
// rsadecrypt compares is a result with the input it must equal.

// return neg, 0, pos as abs(b1)-abs(b2) is neg, 0, pos
int
mpmagcmp(mpint *b1, mpint *b2)
{
	int i;

	i = b1->top - b2->top;
	if(i)
		return i;

	return mpveccmp(b1->p, b1->top, b2->p, b2->top);
}

// return neg, 0, pos as b1-b2 is neg, 0, pos
int
mpcmp(mpint *b1, mpint *b2)
{
	if(b1->sign != b2->sign)
		return b1->sign - b2->sign;
	if(b1->sign < 0)
		return mpmagcmp(b2, b1);
	else
		return mpmagcmp(b1, b2);
}
