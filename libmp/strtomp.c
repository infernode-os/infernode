#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "dat.h"

typedef struct Tab Tab;
struct Tab {
	uchar	t64[256];
	uchar	t32[256];
	uchar	t16[256];
	uchar	t10[256];
};
static Tab tab;
static int tabinited;

enum {
	INVAL=	255
};

static char set64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char set32[] = "23456789abcdefghijkmnpqrstuvwxyz";
static char set16[] = "0123456789ABCDEF0123456789abcdef";
static char set10[] = "0123456789";

// The tables are made once, at the first conversion, with no lock:
// two processes can both be first (two Dis VMs of the native kernel).
// They were filled in place, starting with every entry "no digit", so
// a reader that came once the other maker had finished read a table
// the second was still filling, and took digits for the end of a
// number.  They are made aside and copied whole: a second copy writes
// the bytes that are there.
static void
init(void)
{
	Tab t;
	char *p;

	memset(&t, INVAL, sizeof t);
	for(p = set64; *p; p++)
		t.t64[(uchar)*p] = p-set64;
	for(p = set32; *p; p++)
		t.t32[(uchar)*p] = p-set32;
	for(p = set16; *p; p++)
		t.t16[(uchar)*p] = (p-set16)%16;
	for(p = set10; *p; p++)
		t.t10[(uchar)*p] = (p-set10);
	tab = t;
	tabinited = 1;
}

// Room in b for a number of bits, or -1: there is no memory, or no
// number is that long.  The converters below return nil for it, and
// strtomp raises once it has freed the number it made: mpbits raised
// from inside them, and that number was lost with the raise.
static int
room(mpint *b, vlong bits)
{
	if(bits > MAXBITS || mpreservetry(b, bits) < 0)
		return -1;
	return 0;
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
	if(room(b, (vlong)(p-a)*4) < 0)
		return nil;
	mpbits(b, (p-a)*4);
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
	if(room(b, (vlong)(p-a)*4 + Dbits) < 0)
		return nil;
	mpbits(b, (p-a)*4 + Dbits);

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
	if(room(b, (vlong)(a-buf)*6) < 0)
		return nil;
	n = a-buf;
	p = malloc(n);
	if(p == nil)
		return buf;	// no number read: it was "a number", of whatever b held
	m = dec64(p, n, buf, n);
	if(m < 0){
		mpwipe(p, n);
		free(p);
		return buf;
	}
	betomp(p, m, b);
	mpwipe(p, n);	// the number's bytes: see dat.h
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
	if(room(b, (vlong)(a-buf)*5) < 0)
		return nil;
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
	mpwipe(p, n);	// the number's bytes: see dat.h
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

	if(tabinited == 0)
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

	// no room for it: said as libmp says it, with nothing left behind
	if(e == nil){
		if(alloced)
			mpfree(b);
		sysfatal("strtomp: number too large");
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
