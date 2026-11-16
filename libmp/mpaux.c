#include "os.h"
#include <mp.h>
#include "dat.h"

static mpdigit _mptwodata[1] = { 2 };
static mpint _mptwo =
{
	1,
	1,
	1,
	_mptwodata,
	MPstatic
};
mpint *mptwo = &_mptwo;

static mpdigit _mponedata[1] = { 1 };
static mpint _mpone =
{
	1,
	1,
	1,
	_mponedata,
	MPstatic
};
mpint *mpone = &_mpone;

static mpdigit _mpzerodata[1] = { 0 };
static mpint _mpzero =
{
	1,
	1,
	0,
	_mpzerodata,
	MPstatic
};
mpint *mpzero = &_mpzero;

static int mpmindigits = 33;

// set minimum digit allocation
void
mpsetminbits(int n)
{
	if(n < 0)
		sysfatal("mpsetminbits: n < 0");
	if(n == 0)
		n = 1;
	mpmindigits = DIGITS(n);
}

// allocate an n bit 0'd number, or nil if there is no memory
mpint*
mptrynew(int n)
{
	mpint *b;

	if(n < 0)
		sysfatal("mpnew: n < 0");
	if(n > MAXBITS)
		sysfatal("mpnew: number too large");

	b = mallocz(sizeof(mpint), 1);
	if(b == nil)
		return nil;
	n = DIGITS(n);
	if(n < mpmindigits)
		n = mpmindigits;
	b->p = (mpdigit*)mallocz(n*Dbytes, 1);
	if(b->p == nil){
		free(b);	// it was lost with the raise
		return nil;
	}
	b->size = n;
	b->sign = 1;

	return b;
}

// allocate an n bit 0'd number 
mpint*
mpnew(int n)
{
	mpint *b;

	b = mptrynew(n);
	if(b == nil)
		sysfatal("mpnew: %r");
	return b;
}

// room for n bits, the number unchanged
void
mpreserve(mpint *b, int m)
{
	int n;
	mpdigit *p;

	if(m < 0 || m > MAXBITS)
		sysfatal("mpbits: number too large");
	n = DIGITS(m);
	if(b->size >= n)
		return;
	p = (mpdigit*)mallocz(n*Dbytes, 1);
	if(p == nil)
		sysfatal("mpbits: %r");
	memmove(p, b->p, b->top*Dbytes);
	memset(b->p, 0, b->size*Dbytes);
	free(b->p);
	b->p = p;
	b->size = n;
}

// bits for nd digits and extra more bits: a size made of other sizes,
// in 64 bits, refused if it is more than a number may have (see dat.h)
int
mpsizebits(vlong nd, vlong extra, char *who)
{
	vlong bits;

	bits = MAXBITS+1;
	if(nd >= 0 && extra >= 0 && nd <= MAXBITS/Dbits && extra <= MAXBITS)
		bits = nd*Dbits + extra;
	if(bits > MAXBITS)
		sysfatal("%s: number too large", who);
	return bits;
}

// guarantee at least n significant bits
void
mpbits(mpint *b, int m)
{
	int n;
	mpdigit *p;

	// a count that had wrapped was taken for none: see dat.h
	if(m < 0 || m > MAXBITS)
		sysfatal("mpbits: number too large");
	n = DIGITS(m);
	if(b->size >= n){
		if(b->top >= n)
			return;
		memset(&b->p[b->top], 0, Dbytes*(n - b->top));
		b->top = n;
		return;
	}
	// a block of its own, so that the old digits can be cleared as
	// mpfree clears them (realloc freed them as they were), and are
	// still the number's if there is no room for more (the number was
	// left with none)
	p = (mpdigit*)malloc(n*Dbytes);
	if(p == nil)
		sysfatal("mpbits: %r");
	memmove(p, b->p, b->top*Dbytes);
	memset(b->p, 0, b->size*Dbytes);
	free(b->p);
	b->p = p;
	memset(&b->p[b->top], 0, Dbytes*(n - b->top));
	b->size = n;
	b->top = n;
}

void
mpfree(mpint *b)
{
	if(b == nil)
		return;
	if(b->flags & MPstatic)
		sysfatal("freeing mp constant");
	memset(b->p, 0, b->size*Dbytes);	// information hiding
	free(b->p);
	free(b);
}

void
mpnorm(mpint *b)
{
	int i;

	for(i = b->top-1; i >= 0; i--)
		if(b->p[i] != 0)
			break;
	b->top = i+1;
	if(b->top == 0)
		b->sign = 1;
}

mpint*
mpcopy(mpint *old)
{
	mpint *new;

	new = mpnew(Dbits*old->size);
	new->top = old->top;
	new->sign = old->sign;
	memmove(new->p, old->p, Dbytes*old->top);
	return new;
}

void
mpassign(mpint *old, mpint *new)
{
	mpbits(new, Dbits*old->top);
	new->sign = old->sign;
	new->top = old->top;
	memmove(new->p, old->p, Dbytes*old->top);
}

// number of significant bits in mantissa
int
mpsignif(mpint *n)
{
	int i, j;
	mpdigit d;

	if(n->top == 0)
		return 0;
	for(i = n->top-1; i >= 0; i--){
		d = n->p[i];
		for(j = Dbits-1; j >= 0; j--){
			if(d & (((mpdigit)1)<<j))
				return i*Dbits + j + 1;
		}
	}
	return 0;
}

// k, where n = 2**k * q for odd q
int
mplowbits0(mpint *n)
{
	int k, bit, digit;
	mpdigit d;

	if(n->top==0)
		return 0;
	k = 0;
	bit = 0;
	digit = 0;
	d = n->p[0];
	for(;;){
		if(d & ((mpdigit)1<<bit))
			break;
		k++;
		bit++;
		if(bit==Dbits){
			if(++digit >= n->top)
				return 0;
			d = n->p[digit];
			bit = 0;
		}
	}
	return k;
}

