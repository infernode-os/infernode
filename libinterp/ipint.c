#include "lib9.h"
#include "kernel.h"
#include <isa.h>
#include "interp.h"
#include "runt.h"
#include <mp.h>
#include <libsec.h>
#include "pool.h"
#include "ipint.h"
#include "raise.h"

#include "ipintsmod.h"

/* when a long computation leaves the VM to other threads: see IPint_expmod */
enum
{
	ExpRelModBits=	512,	/* expmod: a modulus longer than this */
	ExpRelExpBits=	32,	/* and an exponent longer than this */
	InvRelBits=	1024,	/* invert: a modulus longer than this (1 ms at 2048 bits) */
	OpRelBits=	16384,	/* mul, div, mod, text: an operand longer than this */
};

/* infinite precision integer */
struct IPint
{
	IPints_IPint x;
	mpint*	b;
};

Type	*TIPint;
static uchar IPintmap[] = IPints_IPint_map;

#define	MP(x)	checkIPint((x))

void
ipintsmodinit(void)
{
	/* can be called from modinit, Keyring or Crypt */
	if(TIPint == nil)
		TIPint = dtype(freeIPint, sizeof(IPint), IPintmap, sizeof(IPintmap));
	builtinmod("$IPints", IPintsmodtab, IPintsmodlen);
}

//IPints_IPint*
void*
newIPint(mpint* b)
{
	Heap *h;
	IPint *ip;

	if(b == nil)
		error(exHeap);
	h = heap(TIPint);	/* TO DO: caller might lose other values if heap raises error here */
	ip = H2D(IPint*, h);
	ip->b = b;
	return (IPints_IPint*)ip;
}

mpint*
checkIPint(void *a)
{
	IPints_IPint *v;
	IPint *ip;

	v = a;
	ip = (IPint*)v;
	if(ip == H || ip == nil)
		error(exNilref);
	if(D2H(ip)->t != TIPint)
		error(exType);
	return ip->b;	/* non-nil by construction */
}

void
freeIPint(Heap *h, int swept)
{
	IPint *ip;

	USED(swept);
	ip = H2D(IPint*, h);
	if(ip->b)
		mpfree(ip->b);
	freeheap(h, 0);
}

/*
 * A number's bytes and text are as long as the number, which is as long
 * as a program makes it (a shift, a product, bytes of its own). They
 * were formatted into 1024 bytes on the stack whatever the length:
 * libmp's hexadecimal filled the buffer and left it unterminated, so
 * the string returned ran on into the stack beyond it; its base 32
 * wrote nothing, and the string was what the stack held; decimal gave
 * the low digits alone; base 64 a shorter number that read back as
 * another; and the bytes of a number past 1024 were an empty array. The
 * room is now taken from the number, in the Dis heap: what is made of
 * it can raise for want of heap, and an array nothing refers to is the
 * collector's to free, where malloc'd memory would be lost.
 */
static int
nbytes(mpint *b)
{
	int n;

	n = (mpsignif(b)+7)/8;
	if(n == 0)
		n = 1;	/* zero is one byte */
	return n;
}

static Array*
mpbytes(mpint *b)
{
	Array *a;
	int n;

	n = nbytes(b);
	a = H2D(Array*, heaparray(&Tbyte, n));
	if(mptobe(b, a->data, n, nil) != n){
		destroy(a);
		error(exHeap);
	}
	return a;
}

static void
retmptoa(mpint *b, int base, String **ret)
{
	Array *a;
	mpint *c;
	char *s;
	int n;

	/* libmp's own allowance: enough for any base, a sign and the terminator */
	n = ((b->top+1)*Dbits+2)/3 + 2;
	a = H2D(Array*, heaparray(&Tbyte, n));
	if(mpsignif(b) > OpRelBits){
		/*
		 * decimal takes time as the square of the length (a minute
		 * at 8MB of number): not with the VM held.  The array is
		 * kept from the collector meanwhile.
		 */
		c = mpcopy(b);
		poolimmutable(D2H(a));
		release();
		s = mptoa(c, base, (char*)a->data, n);
		acquire();
		poolmutable(D2H(a));
		mpfree(c);
	}else
		s = mptoa(b, base, (char*)a->data, n);
	if(s == nil){
		destroy(a);
		error(exHeap);
	}
	retstr(s, ret);
	destroy(a);
}

void
IPint_iptob64z(void *fp)
{
	F_IPint_iptob64 *f;
	mpint *b;
	Array *a, *t;
	uchar *p;
	int n, o;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	b = MP(f->i);
	n = nbytes(b);
	a = H2D(Array*, heaparray(&Tbyte, n+1));
	p = a->data;
	n = mptobe(b, p+1, n, nil);
	if(n < 0){
		destroy(a);
		return;
	}
	p[0] = 0;
	if(n != 0 && (p[1]&0x80)){
		/* force leading 0 byte for compatibility with older representation */
		o = 0;
		n++;
	}else
		o = 1;
	t = H2D(Array*, heaparray(&Tbyte, (n+2)/3*4 + 1));
	enc64((char*)t->data, t->len, p+o, n);
	retstr((char*)t->data, f->ret);
	destroy(t);
	destroy(a);
}

void
IPint_iptob64(void *fp)
{
	F_IPint_iptob64 *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	retmptoa(MP(f->i), 64, f->ret);
}

void
IPint_iptobytes(void *fp)
{
	F_IPint_iptobytes *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	/* TO DO: two's complement or have ipmagtobe? */
	*f->ret = mpbytes(MP(f->i));	/* for now we'll ignore sign */
}

void
IPint_iptobebytes(void *fp)
{
	F_IPint_iptobebytes *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = mpbytes(MP(f->i));
}

void
IPint_iptostr(void *fp)
{
	F_IPint_iptostr *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	retmptoa(MP(f->i), f->base, f->ret);
}

static IPints_IPint*
strtoipint(String *s, int base)
{
	char *p, *q;
	mpint *b;

	p = string2c(s);
	b = strtomp(p, &q, base, nil);
	if(b == nil)
		return H;
	while(*q == '=')
		q++;
	if(q == p || *q != 0){
		mpfree(b);
		return H;
	}
	return newIPint(b);
}

void
IPint_b64toip(void *fp)
{
	F_IPint_b64toip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = strtoipint(f->str, 64);
}

void
IPint_bytestoip(void *fp)
{
	F_IPint_bytestoip *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	if(f->buf == H)
		error(exNilref);

	b = betomp(f->buf->data, f->buf->len, nil);	/* for now we'll ignore sign */
	*f->ret = newIPint(b);
}

void
IPint_bebytestoip(void *fp)
{
	F_IPint_bebytestoip *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	if(f->mag == H)
		error(exNilref);

	b = betomp(f->mag->data, f->mag->len, nil);
	*f->ret = newIPint(b);
}

void
IPint_strtoip(void *fp)
{
	F_IPint_strtoip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = strtoipint(f->str, f->base);
}

enum {
	Maxshiftbits	= 1<<26,	/* 8MB of number: see the shifts */
	Maxprimebits	= 1<<16,
};

/*
 * A count of bits for a random number or a prime is the program's.
 * genprime takes its number's top digit from the count: with none or
 * fewer it masked and set a word before the digits, in the block in
 * front of them in the kernel's pool (minus a thousand ended the
 * emulator: "pool main CORRUPT"), and near the largest int the digit
 * count wrapped and the word was a quarter of a gigabyte away. One bit
 * has no prime, and the search never ended (libsec's probably_prime
 * looked for ever for a witness for 3, which every search from below it
 * meets). A count is held to what the generator can make.
 */
static void
bitscheck(int n, int min, int max)
{
	if(n < min || n > max)
		error("IPint: bad bit count");
}

/* create a random integer */
void
IPint_random(void *fp)
{
	F_IPint_random *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	bitscheck(f->nbits, 0, Maxshiftbits);
	release();
	b = mprand(f->nbits, genrandom, nil);
	acquire();
	*f->ret = newIPint(b);
}

/* number of bits in number */
void
IPint_bits(void *fp)
{
	F_IPint_bits *f;
	int n;

	f = fp;
	*f->ret = 0;
	if(f->i == H)
		return;

	n = mpsignif(MP(f->i));
	if(n == 0)
		n = 1;	/* compatibility */
	*f->ret = n;
}

/* create a new IP from an int */
void
IPint_inttoip(void *fp)
{
	F_IPint_inttoip *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = newIPint(itomp(f->i, nil));
}

void
IPint_iptoint(void *fp)
{
	F_IPint_iptoint *f;

	f = fp;
	*f->ret = 0;
	if(f->i == H)
		return;
	*f->ret = mptoi(MP(f->i));
}

/*
 * Long computations leave the Dis VM to other threads while they run:
 * the builtin calls release() before and acquire() after, as Keyring's
 * sign, verify and genSK and the prime generators below do.  Held, a
 * 2048-bit expmod with a 2048-bit exponent (Inferno's Diffie-Hellman,
 * secstore3) stopped every Limbo thread for 90 ms on a fast x86 and for
 * seconds on a Raspberry Pi.
 *
 * While released this thread must touch nothing in the Limbo heap (the
 * collector and every other thread run) and must not raise: an error()
 * would unwind into the interpreter without the VM.  So the operands are
 * copied out of their IPints first, every error libmp would raise for
 * them is raised before release() or after acquire() instead, and the
 * result's IPint is made after acquire().  (libmp still raises if malloc
 * fails, as genprime and the others here always have.)
 *
 * A switch of thread costs tens of microseconds, so only operations
 * expected to take longer than about a millisecond on a fast x86
 * release: an RSA public-key operation (e = 65537, 0.6 ms at 2048 bits;
 * TLS's certificate checks) keeps the VM.
 */

static int
bigop(mpint *a, mpint *b)
{
	return mpsignif(a) > OpRelBits || mpsignif(b) > OpRelBits;
}

/* modular exponentiation */
void
IPint_expmod(void *fp)
{
	F_IPint_expmod *f;
	mpint *ret, *mod, *base, *exp;
	int rel, nb;
	vlong bits;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	base = MP(f->base);
	exp = MP(f->exp);
	if(f->mod != H)
		mod = MP(f->mod);
	else
		mod = nil;
	/*
	 * what libmp would raise, raised before the result is allocated
	 * (it was lost at each raise) and before the VM is let go
	 */
	if(mpcmp(exp, mpzero) < 0)
		error("mpexp: negative exponent");
	if(mod != nil && mod->top == 0 && exp->top != 0)
		error("mpdiv: divide by zero");
	rel = mpsignif(exp) > OpRelBits;	/* a loop that long, whatever it multiplies */
	if(mod != nil){
		if(mpsignif(mod) > ExpRelModBits && mpsignif(exp) > ExpRelExpBits)
			rel = 1;
	}else{
		/*
		 * With no modulus the result is as long as the base times
		 * the exponent, and it was computed with the VM held
		 * whatever that came to: two to the power of 2**30 stopped
		 * every Limbo thread for minutes. A result is no longer
		 * than a shift may make one, and a long one is computed
		 * with the VM let go, as a long product is.
		 */
		nb = mpsignif(base);
		if(nb > 1 && exp->top != 0){
			if(mpsignif(exp) > 31)
				error("IPint: number too large");
			bits = (vlong)mptoi(exp)*nb;
			if(bits > Maxshiftbits)
				error("IPint: number too large");
			if(bits > OpRelBits)
				rel = 1;
		}
	}
	ret = mpnew(0);
	if(rel){
		/* mod is not zero, exp is positive: mpexp cannot raise */
		base = mpcopy(base);
		exp = mpcopy(exp);
		if(mod != nil)
			mod = mpcopy(mod);
		release();
		mpexp(base, exp, mod, ret);
		acquire();
		mpfree(base);
		mpfree(exp);
		mpfree(mod);
	}else
		mpexp(base, exp, mod, ret);
	*f->ret = newIPint(ret);
}

/* multiplicative inverse */
void
IPint_invert(void *fp)
{
	F_IPint_invert *f;
	mpint *ret, *base, *mod, *g, *dc;
	int ok, zero, rel;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	base = MP(f->base);
	mod = MP(f->mod);
	zero = mod->top == 0;
	rel = mpsignif(mod) > InvRelBits;

	/*
	 * mpinvert, its "no inverse" and its division by a modulus of
	 * zero raised here once everything is freed (libmp raised them
	 * itself for a short modulus, and the result was lost each time),
	 * and after acquire()
	 */
	ret = mpnew(0);
	g = mpnew(0);
	dc = mpnew(0);
	if(rel){
		base = mpcopy(base);
		mod = mpcopy(mod);
		release();
	}
	mpextendedgcd(base, mod, g, ret, dc);
	ok = mpcmp(g, mpone) == 0;
	if(ok && !zero)
		mpmod(ret, mod, ret);
	if(rel){
		acquire();
		mpfree(base);
		mpfree(mod);
	}
	mpfree(g);
	mpfree(dc);
	if(!ok || zero){
		mpfree(ret);
		if(!ok)
			error("mpinvert: no inverse");	/* as libmp would */
		error("mpdiv: divide by zero");
	}
	*f->ret = newIPint(ret);
}

/* basic math */
void
IPint_add(void *fp)
{
	F_IPint_add *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpadd(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_sub(void *fp)
{
	F_IPint_sub *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpsub(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_mul(void *fp)
{
	F_IPint_mul *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(bigop(i1, i2)){
		i1 = mpcopy(i1);
		i2 = mpcopy(i2);
		release();
		mpmul(i1, i2, ret);
		acquire();
		mpfree(i1);
		mpfree(i2);
	}else
		mpmul(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_div(void *fp)
{
	F_IPint_div *f;
	mpint *i1, *i2, *quo, *rem;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	/* as libmp would, but before there is a quotient to lose */
	if(i2->top == 0)
		error("mpdiv: divide by zero");
	quo = mpnew(0);
	if(quo == nil)
		error(exHeap);
	rem = mpnew(0);
	if(rem == nil){
		mpfree(quo);
		error(exHeap);
	}
	if(bigop(i1, i2)){
		/* the divisor is not zero: mpdiv cannot raise */
		i1 = mpcopy(i1);
		i2 = mpcopy(i2);
		release();
		mpdiv(i1, i2, quo, rem);
		acquire();
		mpfree(i1);
		mpfree(i2);
	}else
		mpdiv(i1, i2, quo, rem);

	f->ret->t0 = newIPint(quo);
	f->ret->t1 = newIPint(rem);
}
void
IPint_mod(void *fp)
{
	F_IPint_mod *f;
	mpint *i1, *i2, *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	if(i2->top == 0)
		error("mpdiv: divide by zero");	/* see IPint_div */
	ret = mpnew(0);
	if(bigop(i1, i2)){
		/* the divisor is not zero: mpmod cannot raise */
		i1 = mpcopy(i1);
		i2 = mpcopy(i2);
		release();
		mpmod(i1, i2, ret);
		acquire();
		mpfree(i1);
		mpfree(i2);
	}else
		mpmod(i1, i2, ret);

	*f->ret = newIPint(ret);
}
void
IPint_neg(void *fp)
{
	F_IPint_neg *f;
	mpint *ret;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	ret = mpcopy(MP(f->i));
	if(ret == nil)
		error(exHeap);
	/* zero has no sign: its negative equalled no zero, and printed "-0" */
	if(ret->top != 0)
		ret->sign = -ret->sign;

	*f->ret = newIPint(ret);
}

/* copy */
void
IPint_copy(void *fp)
{
	F_IPint_copy *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	*f->ret = newIPint(mpcopy(MP(f->i)));
}


/* equality */
void
IPint_eq(void *fp)
{
	F_IPint_eq *f;

	f = fp;
	*f->ret = mpcmp(MP(f->i1), MP(f->i2)) == 0;
}

/* compare */
void
IPint_cmp(void *fp)
{
	F_IPint_eq *f;

	f = fp;
	*f->ret = mpcmp(MP(f->i1), MP(f->i2));
}

/* shifts */
/*
 * A shift's count is the program's. libmp added it to the number's own
 * bits in an int: near the largest int the sum wrapped, no room was
 * made, and the digits were stored a quarter of a gigabyte past a block
 * of a hundred bytes; the most negative int, which is its own negative,
 * sent mpleft and mpright calling each other without end; and a count
 * merely large asked the pool for more than it has, which libmp answers
 * by ending the emulator. A number here is no longer than Maxshiftbits.
 */
static void
shiftcheck(mpint *i, int n)
{
	if(n <= 0)
		return;
	if(n > Maxshiftbits || i->top > (Maxshiftbits - n)/Dbits)
		error("IPint: shift too large");
}

void
IPint_shl(void *fp)
{
	F_IPint_shl *f;
	mpint *ret, *i;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	shiftcheck(i, f->n);
	ret = mpnew(0);
	if(ret != nil)
		mpleft(i, f->n, ret);
	*f->ret = newIPint(ret);
}
void
IPint_shr(void *fp)
{
	F_IPint_shr *f;
	mpint *ret, *i;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	/* a right shift by less than nothing is a left shift */
	if(f->n < 0)
		shiftcheck(i, (uint)f->n == ~(~0U>>1)? Maxshiftbits+1: -f->n);
	ret = mpnew(0);
	if(ret != nil)
		mpright(i, f->n, ret);
	*f->ret = newIPint(ret);
}

static void
mpand(mpint *b, mpint *m, mpint *res)
{
	int i;

	res->sign = b->sign;
	if(b->top == 0 || m->top == 0){
		res->top = 0;
		res->sign = 1;	/* as mpnorm leaves a zero */
		return;
	}
	mpbits(res, b->top*Dbits);
	res->top = b->top;
	for(i = b->top; --i >= 0;){
		if(i < m->top)
			res->p[i] = b->p[i] & m->p[i];
		else
			res->p[i] = 0;
	}
	mpnorm(res);
}

static void
mpor(mpint *b1, mpint *b2, mpint *res)
{
	mpint *t;
	int i;

	if(b2->top > b1->top){
		t = b1;
		b1 = b2;
		b2 = t;
	}
	if(b1->top == 0){
		mpassign(b2, res);
		return;
	}
	if(b2->top == 0){
		mpassign(b1, res);
		return;
	}
	mpassign(b1, res);
	for(i = b2->top; --i >= 0;)
		res->p[i] |= b2->p[i];
	mpnorm(res);
}

static void
mpxor(mpint *b1, mpint *b2, mpint *res)
{
	mpint *t;
	int i;

	if(b2->top > b1->top){
		t = b1;
		b1 = b2;
		b2 = t;
	}
	if(b1->top == 0){
		mpassign(b2, res);
		return;
	}
	if(b2->top == 0){
		mpassign(b1, res);
		return;
	}
	mpassign(b1, res);
	for(i = b2->top; --i >= 0;)
		res->p[i] ^= b2->p[i];
	mpnorm(res);
}

static void
mpnot(mpint *b1, mpint *res)
{
	int i;

	mpbits(res, Dbits*b1->top);
	res->sign = 1;
	res->top = b1->top;
	for(i = res->top; --i >= 0;)
		res->p[i] = ~b1->p[i];
	mpnorm(res);
}

/* bits */
void
IPint_and(void *fp)
{
	F_IPint_and *f;
	mpint *ret, *i1, *i2;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpand(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_ori(void *fp)
{
	F_IPint_ori *f;
	mpint *ret, *i1, *i2;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpor(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_xor(void *fp)
{
	F_IPint_xor *f;
	mpint *ret, *i1, *i2;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	ret = mpnew(0);
	if(ret != nil)
		mpxor(i1, i2, ret);
	*f->ret = newIPint(ret);
}

void
IPint_not(void *fp)
{
	F_IPint_not *f;
	mpint *ret, *i1;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	ret = mpnew(0);
	if(ret != nil)
		mpnot(i1, ret);
	*f->ret = newIPint(ret);
}

/*
 * primes
 */

void
IPints_probably_prime(void *fp)
{
	F_IPints_probably_prime *f;
	mpint *n;
	int r;

	f = fp;
	n = checkIPint(f->n);
	if(n->sign < 0)
		error("negative prime candidate");	/* as libsec would */
	release();
	r = probably_prime(n, f->nrep);
	acquire();
	*f->ret = r;
}

void
IPints_genprime(void *fp)
{
	F_IPints_genprime *f;
	mpint *p;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	bitscheck(f->nbits, 2, Maxprimebits);
	p = mpnew(0);
	release();
	genprime(p, f->nbits, f->nrep);
	acquire();
	*f->ret = newIPint(p);
}

void
IPints_genstrongprime(void *fp)
{
	F_IPints_genstrongprime *f;
	mpint *p;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	bitscheck(f->nbits < 64? 64: f->nbits, 64, Maxprimebits);	/* fewer than 64 bits are 64 */
	p = mpnew(0);
	release();
	genstrongprime(p, f->nbits, f->nrep);
	acquire();
	*f->ret = newIPint(p);
}

void
IPints_gensafeprime(void *fp)
{
	F_IPints_gensafeprime *f;
	mpint *p, *alpha;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);

	bitscheck(f->nbits, 3, Maxprimebits);	/* the least safe prime is 7 */
	p = mpnew(0);
	alpha = mpnew(0);
	release();
	gensafeprime(p, alpha, f->nbits, f->nrep);
	acquire();
	f->ret->t0 = newIPint(p);
	f->ret->t1 = newIPint(alpha);
}

void
IPints_DSAprimes(void *fp)
{
	F_IPints_DSAprimes *f;
	mpint *p, *q;
	Heap *h;
	void *v;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);
	v = f->ret->t2;
	f->ret->t2 = H;
	destroy(v);

	h = heaparray(&Tbyte, SHA1dlen);
	f->ret->t2 = H2D(Array*, h);

	p = mpnew(0);
	q = mpnew(0);
	release();
	DSAprimes(q, p, f->ret->t2->data);
	acquire();
	f->ret->t0 = newIPint(q);
	f->ret->t1 = newIPint(p);
}
