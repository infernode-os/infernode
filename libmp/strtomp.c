#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "dat.h"

static struct {
	int	inited;

	uchar	t64[256];
	uchar	t32[256];
	uchar	t16[256];
	uchar	t10[256];
} tab;

enum {
	INVAL=	255
};

static char set64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char set32[] = "23456789abcdefghijkmnpqrstuvwxyz";
static char set16[] = "0123456789ABCDEF0123456789abcdef";
static char set10[] = "0123456789";

static void
init(void)
{
	char *p;

	memset(tab.t64, INVAL, sizeof(tab.t64));
	memset(tab.t32, INVAL, sizeof(tab.t32));
	memset(tab.t16, INVAL, sizeof(tab.t16));
	memset(tab.t10, INVAL, sizeof(tab.t10));

	for(p = set64; *p; p++)
		tab.t64[*p] = p-set64;
	for(p = set32; *p; p++)
		tab.t32[*p] = p-set32;
	for(p = set16; *p; p++)
		tab.t16[*p] = (p-set16)%16;
	for(p = set10; *p; p++)
		tab.t10[*p] = (p-set10);

	tab.inited = 1;
}

static char*
from16(char *a, mpint *b)
{
	char *p, *next;
	int i;
	mpdigit x;

	b->top = 0;
	for(p = a; *p; p++)
		if(tab.t16[*(uchar*)p] == INVAL)
			break;
	// the digits' bits were an int: see dat.h
	mpbits(b, mpsizebits(0, (vlong)(p-a)*4, "strtomp"));
	b->top = 0;
	next = p;
	while(p > a){
		x = 0;
		for(i = 0; i < Dbits; i += 4){
			if(p <= a)
				break;
			x |= (mpdigit)tab.t16[*(uchar*)--p]<<i;
		}
		b->p[b->top++] = x;
	}
	return next;
}

static ulong mppow10[] = {
	1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000
};

// b = b*m + a, in place; b has room for a digit more
static void
muladd(mpint *b, ulong m, ulong a)
{
	uvlong x;
	int i;

	x = a;
	for(i = 0; i < b->top; i++){
		x += (uvlong)b->p[i]*m;
		b->p[i] = x;
		x >>= Dbits;
	}
	if(x != 0)
		b->p[b->top++] = x;
}

static char*
from10(char *a, mpint *b)
{
	ulong x, y;
	mpint *pow, *r;
	char *p;
	int i;

	// room for all of it first: four bits a digit is more than enough
	// (and the count of them an int's worth: see dat.h)
	for(p = a; tab.t10[*(uchar*)p] != INVAL; p++)
		;
	mpbits(b, mpsizebits(1, (vlong)(p-a)*4, "strtomp"));

	pow = nil;
	r = nil;
	if(Dbits > 32){
		pow = mpnew(0);
		r = mpnew(0);
	}

	b->top = 0;
	for(;;){
		// do a billion at a time in native arithmetic
		x = 0;
		for(i = 0; i < 9; i++){
			y = tab.t10[*(uchar*)a];
			if(y == INVAL)
				break;
			a++;
			x *= 10;
			x += y;
		}
		if(i == 0)
			break;

		// accumulate into mpint.  (mpmul and mpadd did it, with a
		// copy of the number made and freed for every nine digits)
		if(Dbits > 32){
			uitomp(mppow10[i], pow);
			uitomp(x, r);
			mpmul(b, pow, b);
			mpadd(b, r, b);
		}else
			muladd(b, mppow10[i], x);
		if(i != 9)
			break;
	}
	mpfree(pow);
	mpfree(r);
	return a;
}

static char*
from64(char *a, mpint *b)
{
	char *buf = a;
	uchar *p;
	int n, m;

	for(; tab.t64[*(uchar*)a] != INVAL; a++)
		;
	mpsizebits(0, (vlong)(a-buf)*6, "strtomp");
	n = a-buf;
	p = malloc(n);
	if(p == nil)
		return buf;	// no number read: it was "a number", of whatever b held
	m = dec64(p, n, buf, n);
	if(m < 0){
		free(p);
		return buf;
	}
	betomp(p, m, b);
	free(p);
	return a;
}

static char*
from32(char *a, mpint *b)
{
	char *buf = a;
	uchar *p;
	int n, m;

	// base 32's own digits (base 64's were looked for, and the ones
	// that are not base 32's read as zeros)
	for(; tab.t32[*(uchar*)a] != INVAL; a++)
		;
	mpsizebits(0, (vlong)(a-buf)*5, "strtomp");
	n = a-buf;
	p = malloc(n);
	if(p == nil)
		return buf;	// see from64
	m = dec32(p, n, buf, n);
	if(m < 0){
		// not a length base 32 has (1, 3 or 6 digits past a multiple
		// of 8): dec32's -1 went to betomp as a count of bytes
		free(p);
		return buf;
	}
	betomp(p, m, b);
	free(p);
	return a;
}

mpint*
strtomp(char *a, char **pp, int base, mpint *b)
{
	int sign, alloced;
	char *e;

	alloced = 0;
	if(b == nil){
		b = mpnew(0);
		alloced = 1;
	}

	if(tab.inited == 0)
		init();

	while(*a==' ' || *a=='\t')
		a++;

	sign = 1;
	for(;; a++){
		switch(*a){
		case '-':
			sign *= -1;
			continue;
		}
		break;
	}

	switch(base){
	case 10:
		e = from10(a, b);
		break;
	default:
	case 16:
		e = from16(a, b);
		break;
	case 32:
		e = from32(a, b);
		break;
	case 64:
		e = from64(a, b);
		break;
	}

	// if no characters parsed, there wasn't a number to convert
	// (and the number made here for it is not the caller's to free:
	// each string that was no number cost one)
	if(e == a){
		if(alloced)
			mpfree(b);
		return nil;
	}

	// zero has no sign: "-0" was a zero that equalled no zero and
	// printed as it was read
	mpnorm(b);
	if(b->top != 0)
		b->sign = sign;
	if(pp != nil)
		*pp = e;

	return b;
}
