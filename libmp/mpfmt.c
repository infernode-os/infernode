#include "os.h"
#include <mp.h>
#include <libsec.h>
#include "dat.h"

static int
to64(mpint *b, char *buf, int len)
{
	uchar *p;
	int n, rv;

	p = nil;
	n = mptobe(b, nil, 0, &p);
	if(n < 0)
		return -1;
	// all of it or none: enc64 stops where the room does, and what it
	// had written was returned as the number
	if(len < 4*((n+2)/3) + 1){
		free(p);
		return -1;
	}
	rv = enc64(buf, len, p, n);
	free(p);
	return rv;
}

static int
to32(mpint *b, char *buf, int len)
{
	uchar *p;
	int n, rv, pad;

	// leave room for a multiple of 5 buffer size
	n = b->top*Dbytes + 5;
	p = malloc(n);
	if(p == nil)
		return -1;
	n = mptobe(b, p, n, nil);
	if(n < 0){
		free(p);
		return -1;
	}

	// round up buffer size, enc32 only accepts a multiple of 5.
	// The bytes of zero go in front of the number: after it they
	// multiplied it by 256 for each (1, 256 and 65536 were one text,
	// which read back as 2^32)
	pad = (5 - n%5)%5;
	if(pad != 0){
		memmove(p+pad, p, n);
		memset(p, 0, pad);
		n += pad;
	}
	rv = enc32(buf, len, p, n);
	free(p);
	return rv;
}

static char set16[] = "0123456789ABCDEF";

static int
to16(mpint *b, char *buf, int len)
{
	mpdigit *p, x;
	int i, j;
	char *out, *eout;

	if(len < 1)
		return -1;

	out = buf;
	eout = buf+len;
	for(p = &b->p[b->top-1]; p >= b->p; p--){
		x = *p;
		for(i = Dbits-4; i >= 0; i -= 4){
			j = 0xf & (x>>i);
			if(j != 0 || out != buf){
				if(out >= eout)
					return -1;
				*out++ = set16[j];
			}
		}
	}
	if(out == buf)
		*out++ = '0';
	if(out >= eout)
		return -1;
	*out = 0;
	return 0;
}

static char*
modbillion(int rem, ulong r, char *out, char *buf)
{
	ulong rr;
	int i;

	for(i = 0; i < 9; i++){
		rr = r%10;
		r /= 10;
		if(out <= buf)
			return nil;
		*--out = '0' + rr;
		if(rem == 0 && r == 0)
			break;
	}
	return out;
}

// d /= 10^9 in place, the remainder returned.  (mpdiv did it, making
// and freeing two copies of the number for every nine digits: a number
// of half a megabit took half a minute to write)
static ulong
divbillion(mpint *d)
{
	uvlong x;
	int i;

	x = 0;
	for(i = d->top-1; i >= 0; i--){
		x = (x<<Dbits) | d->p[i];
		d->p[i] = x/1000000000;
		x %= 1000000000;
	}
	mpnorm(d);
	return x;
}

static int
to10(mpint *b, char *buf, int len)
{
	mpint *d, *r, *billion;
	char *out;
	ulong rem;

	if(len < 1)
		return -1;

	// (mptrycopy: mpcopy raises with no memory, and the text the
	// caller of this made room for, mptoa's own included, was lost)
	d = mptrycopy(b);
	if(d == nil)
		return -1;
	r = nil;
	billion = nil;
	if(Dbits > 32){
		r = mptrynew(2*Dbits);
		billion = mptrynew(2*Dbits);
		if(r == nil || billion == nil){
			mpfree(d);
			mpfree(r);
			mpfree(billion);
			return -1;
		}
		uitomp(1000000000, billion);
	}
	out = buf+len;
	*--out = 0;
	do {
		if(Dbits > 32){
			mpdiv(d, billion, d, r);
			rem = r->p[0];
		}else
			rem = divbillion(d);
		out = modbillion(d->top, rem, out, buf);
		if(out == nil)
			break;
	} while(d->top != 0);
	mpfree(d);
	mpfree(r);
	mpfree(billion);

	if(out == nil)
		return -1;
	len -= out-buf;
	if(out != buf)
		memmove(buf, out, len);
	return 0;
}

int
mpfmt(Fmt *fmt)
{
	mpint *b;
	char *p;

	b = va_arg(fmt->args, mpint*);
	if(b == nil)
		return fmtstrcpy(fmt, "*");
	
	p = mptoa(b, fmt->prec, nil, 0);
	fmt->flags &= ~FmtPrec;

	if(p == nil)
		return fmtstrcpy(fmt, "*");
	else{
		fmtstrcpy(fmt, p);
		free(p);
		return 0;
	}
}

char*
mptoa(mpint *b, int base, char *buf, int len)
{
	char *out;
	int rv, alloced;

	alloced = 0;
	if(buf == nil){
		len = ((b->top+1)*Dbits+2)/3 + 1;
		buf = malloc(len);
		if(buf == nil)
			return nil;
		alloced = 1;
	}

	if(len < 2)
		return nil;

	out = buf;
	if(b->sign < 0){
		*out++ = '-';
		len--;
	}
	switch(base){
	case 64:
		rv = to64(b, out, len);
		break;
	case 32:
		rv = to32(b, out, len);
		break;
	default:
	case 16:
		rv = to16(b, out, len);
		break;
	case 10:
		rv = to10(b, out, len);
		break;
	}
	if(rv < 0){
		if(alloced)
			free(buf);
		return nil;
	}
	return buf;
}
