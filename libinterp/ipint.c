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

/*
 * How long a number may be, and how much work one call may be.
 *
 * Nothing held a number's size but the shifts. Bytes, text, a product
 * or a sum made one of any length, and libmp counts a number's bits in
 * an int: 256MB of bytes was 2^31 bits, room was made for none of them
 * and they were stored all the same, and the product of a number that
 * long by 3 was written from a block of a hundred bytes on through the
 * kernel's pool. libmp refuses such sizes itself now; here a number is
 * held to Maxbits whatever makes it, which is far past any use in the
 * tree (keys to 8192 bits, the tests' numbers of a few megabits) and
 * leaves a product's scratch a few tens of megabytes.
 *
 * And nothing held the time. A computation in libmp is not interrupted:
 * a Prog killed in one is gone only when it ends, and until then it has
 * one of the host's processors. expmod with a modulus and an exponent
 * of 256K bits each (an hour) could be started by any program, as often
 * as it liked, and so could a division of megabytes by megabytes or an
 * inverse. The operations whose time grows faster than their operands
 * are held to an amount of work that ends in seconds:
 *
 * - expmod with a modulus: the modulus no longer than Maxmodbits, and
 *   (modulus bits)^2 x (exponent bits) no more than Maxexpwork, the
 *   work of a 16384-bit modulus and exponent (RSA-16384's private
 *   operation without the CRT; Diffie-Hellman at 8192 bits is an
 *   eighth of it); a sixteenth of that where libmp takes its general
 *   path (an even modulus), which is that much slower;
 * - expmod with no modulus: a result no longer than Maxpowbits;
 * - mul: (digits) x (digits) no more than Maxmulwork: two numbers of
 *   two megabits, or the longest number by one of 4096 bits (two of
 *   four megabytes took a minute);
 * - div and mod: (quotient digits) x (divisor digits) no more than
 *   Maxdivwork: any number by one of up to 8192 bits, or a megabit by
 *   half a megabit;
 * - invert: both numbers no longer than Maxinvbits;
 * - text in base 10, either way, of a number no longer than
 *   Maxdecbits (the other bases take time as the length);
 * - probably_prime: a candidate no longer than Maxprimebits, the
 *   longest prime the generators make.
 *
 * What is past a limit is refused: "IPint: number too large".
 */
enum
{
	Maxbits=	1<<26,	/* a number: 8MB */
	Maxprimebits=	1<<16,
	Maxmodbits=	1<<15,	/* expmod's modulus */
	Maxinvbits=	1<<16,	/* invert's numbers */
	Maxdecbits=	1<<20,	/* a number written or read in base 10 */
	Maxpowbits=	1<<22,	/* expmod with no modulus: its result */
};
#define	Maxexpwork	((vlong)1<<42)	/* expmod: 16384^3 */
#define	Maxdivwork	((vlong)1<<29)	/* div, mod: digits by digits */
#define	Maxmulwork	((vlong)1<<32)	/* mul: digits by digits */

static char exToolarge[] = "IPint: number too large";

static void
sizecheck(vlong bits)
{
	if(bits > Maxbits)
		error(exToolarge);
}

/* the work of dividing a by b, neither zero */
static void
divcheck(mpint *a, mpint *b)
{
	if(a->top > b->top && (vlong)(a->top - b->top + 1)*b->top > Maxdivwork)
		error(exToolarge);
}

/* infinite precision integer */
struct IPint
{
	IPints_IPint x;
	mpint*	b;
};

Type	*TIPint;
static uchar IPintmap[] = IPints_IPint_map;

enum { Nheld = 5, Heldsize = Nheld*sizeof(mpint*) };
static Type	*THeld;		/* see hold */
static void	freeheld(Heap*, int);

#define	MP(x)	checkIPint((x))

/*
 * Is this process's Prog being killed (the kernels' dis.c)?  Asked by
 * libsec's searches for a prime between candidates, so that a Prog
 * killed in one stops searching: they run with the VM let go, where a
 * kill only marks the Prog, and went on for as long as they took.
 */
extern int	upkilled(void);

void
ipintsmodinit(void)
{
	/* can be called from modinit, Keyring or Crypt */
	secstop = upkilled;
	if(TIPint == nil)
		TIPint = dtype(freeIPint, sizeof(IPint), IPintmap, sizeof(IPintmap));
	if(THeld == nil)
		THeld = dtype(freeheld, Heldsize, nil, 0);
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
	/*
	 * heap() raises when there is no room for the cell, and the number
	 * given, which the caller no longer holds, was lost with the
	 * raise: the cell is made as heap() makes one, and with none the
	 * number is freed first
	 */
	h = nheapok(sizeof(IPint));
	if(h == nil){
		mpfree(b);
		error(exHeap);
	}
	h->t = TIPint;
	TIPint->ref++;
	ip = H2D(IPint*, h);
	memset(ip, 0, sizeof(IPint));
	if(TIPint->np)
		initmem(TIPint, ip);
	ip->b = b;
	return (IPints_IPint*)ip;
}

/*
 * A result's cell, made before the result: its number is libmp's to
 * fill, and when libmp raises (for want of memory) a cell nothing
 * refers to is the collector's to free, its number with it, where a
 * number alone was lost. For results made with the VM held; see hold
 * for the others.
 */
static IPint*
ipcell(void)
{
	IPint *ip;
	mpint *b;

	b = mpnew(0);
	ip = newIPint(b);
	return ip;
}

/*
 * What an operation has while the VM is let go: its copies of the
 * operands and the result it is making. libmp raises when there is no
 * memory for what it is asked (sysfatal is error), the raise leaves
 * through the builtin, and what the builtin had made was lost with it:
 * one product of two 60MB numbers that did not fit left 250MB of the
 * kernel's pool held by nothing, for good, and three such calls left
 * the kernel without memory. A cell nothing refers to will not do here,
 * as the collector runs meanwhile and would free it under the
 * computation. The numbers are kept in a cell of the Dis heap that one
 * of the call's own pointer arguments is made to refer to, through a
 * few that keeps the argument's value beside it: the frame is a root
 * for the collector while the call lasts, another Prog cannot reach it,
 * and its pointers are freed when an exception unwinds it, the cell and
 * its numbers with them. unhold puts the argument back. pin keeps
 * something of the heap's the same way (an array being filled).
 */
typedef struct Held Held;
struct Held
{
	mpint*	m[Nheld];
};

static void
freeheld(Heap *h, int swept)
{
	Held *w;
	int i;

	w = H2D(Held*, h);
	for(i = 0; i < Nheld; i++)
		mpfree(w->m[i]);
	freeheap(h, swept);
}

static Held*
hold(void *slot)
{
	void **arg, **pair;
	Array *a;
	Held *w;

	arg = slot;
	a = H2D(Array*, heaparray(&Tptr, 3));
	w = H2D(Held*, heap(THeld));	/* if this raises, a is the collector's */
	pair = (void**)a->data;
	pair[0] = *arg;
	if(pair[0] != H)
		Setmark(D2H(pair[0]));
	pair[1] = w;
	*arg = a;
	return w;
}

static void
unhold(void *slot)
{
	void **arg, **pair;
	Array *a;

	arg = slot;
	a = *arg;
	pair = (void**)a->data;
	*arg = pair[0];
	if(pair[0] != H)
		Setmark(D2H(pair[0]));
	pair[0] = H;
	destroy(a);
}

static void
pin(void *slot, void *v)
{
	Array *a;

	a = *(void**)slot;
	((void**)a->data)[2] = v;
}

static void*
unpin(void *slot)
{
	Array *a;
	void *v;

	a = *(void**)slot;
	v = ((void**)a->data)[2];
	((void**)a->data)[2] = H;
	return v;
}

/* the number at w->m[i], which is no longer w's */
static mpint*
take(Held *w, int i)
{
	mpint *b;

	b = w->m[i];
	w->m[i] = nil;
	return b;
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

/* arg is the call's own argument, the number's IPint: see hold */
static void
retmptoa(void *arg, int base, String **ret)
{
	Array *a;
	mpint *b;
	Held *w;
	char *s;
	int n;

	b = MP(*(void**)arg);
	/*
	 * decimal takes time as the square of the length (a minute at 8MB
	 * of number, and nothing can end it sooner)
	 */
	if(base == 10 && mpsignif(b) > Maxdecbits)
		error(exToolarge);
	/* libmp's own allowance: enough for any base, a sign and the terminator */
	n = ((b->top+1)*Dbits+2)/3 + 2;
	a = H2D(Array*, heaparray(&Tbyte, n));
	if(mpsignif(b) > OpRelBits){
		/*
		 * not with the VM held.  The array and a copy of the
		 * number are the call's meanwhile: see hold.
		 */
		w = hold(arg);
		pin(arg, a);
		w->m[0] = mpcopy(b);
		release();
		s = mptoa(w->m[0], base, (char*)a->data, n);
		acquire();
		unpin(arg);
		unhold(arg);
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

	retmptoa(&f->i, 64, f->ret);
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

	retmptoa(&f->i, f->base, f->ret);
}

/*
 * arg is the call's own argument, the string. Its digits are held to
 * what a number may have before they are read (a megabyte of decimal
 * digits is a billion multiplications, with nothing to stop them), and
 * a long number in base 10 is read with the VM let go, as it is
 * written.
 */
static IPints_IPint*
strtoipint(void *arg, int base)
{
	String *s;
	char *p, *q;
	mpint *b;
	Held *w;
	vlong n, bits;

	s = *(String**)arg;
	if(s == H)
		return H;
	n = s->len;
	if(n < 0)
		n = -n;
	switch(base){
	case 10:
		/* more than three bits a digit */
		if(n*3 > Maxdecbits+64)
			error(exToolarge);
		bits = n*4;
		break;
	case 32:
		bits = n*5;
		break;
	case 64:
		bits = n*6;
		break;
	default:
		bits = n*4;
		break;
	}
	sizecheck(bits - 64);	/* room for a sign, blanks and padding */

	p = string2c(s);
	if(base == 10 && bits > OpRelBits){
		w = hold(arg);
		w->m[0] = mpnew(0);
		release();
		b = strtomp(p, &q, base, w->m[0]);
		acquire();
		if(b != nil)
			b = take(w, 0);
		unhold(arg);
	}else
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

	*f->ret = strtoipint(&f->str, 64);
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

	sizecheck((vlong)f->buf->len*8);
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

	sizecheck((vlong)f->mag->len*8);
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

	*f->ret = strtoipint(&f->str, f->base);
}

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

	bitscheck(f->nbits, 0, Maxbits);
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

	f = fp;
	*f->ret = 0;
	if(f->i == H)
		return;

	/* zero has no bits (it was given one, "for compatibility": a zero and a one were of a length) */
	*f->ret = mpsignif(MP(f->i));
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
	IPint *r;
	Held *w;
	int rel, nb, mb, eb;
	vlong bits, work;
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
		/*
		 * the time is the modulus's length squared, for each bit
		 * of the exponent: see Maxexpwork
		 */
		mb = mpsignif(mod);
		eb = mpsignif(exp);
		if(mb > Maxmodbits)
			error(exToolarge);
		work = (vlong)mb*mb;
		if(eb != 0 && work > Maxexpwork/eb)
			error(exToolarge);
		/* libmp's general path (see mpexp): sixteen times less */
		if(mod->sign < 0 || (mod->p[0] & 1) == 0)
			if(eb != 0 && work > (Maxexpwork>>4)/eb)
				error(exToolarge);
		/* the base is brought below the modulus first, by division */
		if(mod->top != 0)
			divcheck(base, mod);
		if(mb > ExpRelModBits && eb > ExpRelExpBits)
			rel = 1;
	}else{
		/*
		 * With no modulus the result is as long as the base times
		 * the exponent, and it was computed with the VM held
		 * whatever that came to: two to the power of 2**30 stopped
		 * every Limbo thread for minutes. A result is no longer
		 * than Maxpowbits (its last squaring is the longest
		 * product mul makes), and a long one is computed
		 * with the VM let go, as a long product is.
		 */
		nb = mpsignif(base);
		if(nb > 1 && exp->top != 0){
			if(mpsignif(exp) > 31)
				error(exToolarge);
			bits = (vlong)mptoi(exp)*nb;
			if(bits > Maxpowbits)
				error(exToolarge);
			if(bits > OpRelBits)
				rel = 1;
		}
	}
	if(rel){
		/* mod is not zero, exp is positive: mpexp raises only for want of memory */
		w = hold(&f->base);
		w->m[0] = mpcopy(base);
		w->m[1] = mpcopy(exp);
		if(mod != nil)
			w->m[2] = mpcopy(mod);
		w->m[3] = mpnew(0);
		release();
		/*
		 * the base below the modulus first, in the call's own copy:
		 * mpexp would do it into a number of its own, with nothing
		 * to free it if the division raised
		 */
		if(w->m[2] != nil && w->m[2]->top != 0)
			mpmod(w->m[0], w->m[2], w->m[0]);
		mpexp(w->m[0], w->m[1], w->m[2], w->m[3]);
		acquire();
		ret = take(w, 3);
		unhold(&f->base);
		*f->ret = newIPint(ret);
	}else{
		r = ipcell();
		mpexp(base, exp, mod, r->b);
		*f->ret = (IPints_IPint*)r;
	}
}

/* multiplicative inverse */
void
IPint_invert(void *fp)
{
	F_IPint_invert *f;
	mpint *ret, *base, *mod;
	Held *w;
	int ok, zero, rel;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	base = MP(f->base);
	mod = MP(f->mod);
	zero = mod->top == 0;
	rel = mpsignif(mod) > InvRelBits || mpsignif(base) > InvRelBits;
	/* the time is as the square of the longer: see Maxinvbits */
	if(mpsignif(mod) > Maxinvbits || mpsignif(base) > Maxinvbits)
		error(exToolarge);

	/*
	 * mpinvert, its "no inverse" and its division by a modulus of
	 * zero raised here once everything is freed (libmp raised them
	 * itself for a short modulus, and the result was lost each time),
	 * and after acquire().  The working numbers are the call's: see hold.
	 */
	w = hold(&f->base);
	w->m[0] = mpnew(0);
	w->m[1] = mpnew(0);
	w->m[2] = mpnew(0);
	if(rel){
		w->m[3] = mpcopy(base);
		w->m[4] = mpcopy(mod);
		base = w->m[3];
		mod = w->m[4];
		release();
	}
	mpextendedgcd(base, mod, w->m[1], w->m[0], w->m[2]);
	ok = mpcmp(w->m[1], mpone) == 0;
	if(ok && !zero)
		mpmod(w->m[0], mod, w->m[0]);
	if(rel)
		acquire();
	ret = nil;
	if(ok && !zero)
		ret = take(w, 0);
	unhold(&f->base);
	if(ret == nil){
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
	mpint *i1, *i2;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	sizecheck((vlong)(i1->top > i2->top? i1->top: i2->top)*Dbits + 1);
	r = ipcell();
	mpadd(i1, i2, r->b);
	*f->ret = (IPints_IPint*)r;
}
void
IPint_sub(void *fp)
{
	F_IPint_sub *f;
	mpint *i1, *i2;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	sizecheck((vlong)(i1->top > i2->top? i1->top: i2->top)*Dbits + 1);
	r = ipcell();
	mpsub(i1, i2, r->b);
	*f->ret = (IPints_IPint*)r;
}
void
IPint_mul(void *fp)
{
	F_IPint_mul *f;
	mpint *i1, *i2, *ret;
	IPint *r;
	Held *w;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	/* a product has the bits of both: see Maxbits, and Maxmulwork */
	sizecheck((vlong)mpsignif(i1) + mpsignif(i2));
	if((vlong)i1->top*i2->top > Maxmulwork)
		error(exToolarge);
	if(bigop(i1, i2)){
		w = hold(&f->i1);
		w->m[0] = mpcopy(i1);
		w->m[1] = mpcopy(i2);
		w->m[2] = mpnew(0);
		release();
		mpmul(w->m[0], w->m[1], w->m[2]);
		acquire();
		ret = take(w, 2);
		unhold(&f->i1);
		*f->ret = newIPint(ret);
	}else{
		r = ipcell();
		mpmul(i1, i2, r->b);
		*f->ret = (IPints_IPint*)r;
	}
}
void
IPint_div(void *fp)
{
	F_IPint_div *f;
	mpint *i1, *i2, *quo, *rem;
	IPint *q, *r;
	Held *w;
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
	divcheck(i1, i2);
	if(bigop(i1, i2)){
		/* the divisor is not zero: mpdiv raises only for want of memory */
		w = hold(&f->i1);
		w->m[0] = mpcopy(i1);
		w->m[1] = mpcopy(i2);
		w->m[2] = mpnew(0);
		w->m[3] = mpnew(0);
		release();
		mpdiv(w->m[0], w->m[1], w->m[2], w->m[3]);
		acquire();
		quo = take(w, 2);
		q = newIPint(quo);	/* (the remainder is still the call's if this raises) */
		rem = take(w, 3);
		r = newIPint(rem);
		unhold(&f->i1);
		f->ret->t0 = (IPints_IPint*)q;
		f->ret->t1 = (IPints_IPint*)r;
	}else{
		q = ipcell();
		r = ipcell();
		mpdiv(i1, i2, q->b, r->b);
		f->ret->t0 = (IPints_IPint*)q;
		f->ret->t1 = (IPints_IPint*)r;
	}
}
void
IPint_mod(void *fp)
{
	F_IPint_mod *f;
	mpint *i1, *i2, *ret;
	IPint *r;
	Held *w;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	if(i2->top == 0)
		error("mpdiv: divide by zero");	/* see IPint_div */
	divcheck(i1, i2);
	if(bigop(i1, i2)){
		/* the divisor is not zero: mpmod raises only for want of memory */
		w = hold(&f->i1);
		w->m[0] = mpcopy(i1);
		w->m[1] = mpcopy(i2);
		w->m[2] = mpnew(0);
		release();
		mpmod(w->m[0], w->m[1], w->m[2]);
		acquire();
		ret = take(w, 2);
		unhold(&f->i1);
		*f->ret = newIPint(ret);
	}else{
		r = ipcell();
		mpmod(i1, i2, r->b);
		*f->ret = (IPints_IPint*)r;
	}
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
 * by ending the emulator. A number here is no longer than Maxbits.
 */
static void
shiftcheck(mpint *i, int n)
{
	if(n <= 0)
		return;
	if(n > Maxbits || i->top > (Maxbits - n)/Dbits)
		error("IPint: shift too large");
}

void
IPint_shl(void *fp)
{
	F_IPint_shl *f;
	mpint *i;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	shiftcheck(i, f->n);
	r = ipcell();
	mpleft(i, f->n, r->b);
	*f->ret = (IPints_IPint*)r;
}
void
IPint_shr(void *fp)
{
	F_IPint_shr *f;
	mpint *i;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i = MP(f->i);
	/* a right shift by less than nothing is a left shift */
	if(f->n < 0)
		shiftcheck(i, (uint)f->n == ~(~0U>>1)? Maxbits+1: -f->n);
	r = ipcell();
	mpright(i, f->n, r->b);
	*f->ret = (IPints_IPint*)r;
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
	mpint *i1, *i2;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	r = ipcell();
	mpand(i1, i2, r->b);
	*f->ret = (IPints_IPint*)r;
}

void
IPint_ori(void *fp)
{
	F_IPint_ori *f;
	mpint *i1, *i2;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	r = ipcell();
	mpor(i1, i2, r->b);
	*f->ret = (IPints_IPint*)r;
}

void
IPint_xor(void *fp)
{
	F_IPint_xor *f;
	mpint *i1, *i2;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	i2 = MP(f->i2);
	r = ipcell();
	mpxor(i1, i2, r->b);
	*f->ret = (IPints_IPint*)r;
}

void
IPint_not(void *fp)
{
	F_IPint_not *f;
	mpint *i1;
	IPint *r;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	i1 = MP(f->i1);
	r = ipcell();
	mpnot(i1, r->b);
	*f->ret = (IPints_IPint*)r;
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
	/* each round is an expmod as long as the candidate: see Maxexpwork */
	if(mpsignif(n) > Maxprimebits)
		error(exToolarge);
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
	r = nil;
	if(genprimestop(p, f->nbits, f->nrep, upkilled) < 0)
		r = p;
	acquire();
	if(r != nil){
		/* stopped: this Prog is being killed, and its kill is raised as the call returns */
		mpfree(p);
		return;
	}
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
	r = nil;
	if(genstrongprimestop(p, f->nbits, f->nrep, upkilled) < 0)
		r = p;
	acquire();
	if(r != nil){
		mpfree(p);
		return;
	}
	*f->ret = newIPint(p);
}

void
IPints_gensafeprime(void *fp)
{
	F_IPints_gensafeprime *f;
	mpint *p, *alpha;
	void *v;
	int ok;

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
	ok = gensafeprimestop(p, alpha, f->nbits, f->nrep, upkilled);
	acquire();
	if(ok < 0){
		/*
		 * stopped because this Prog is being killed (its kill is
		 * raised as the call returns), or no prime in all the
		 * candidates the search allows itself: no numbers
		 */
		mpfree(p);
		mpfree(alpha);
		if(!upkilled())
			error("gensafeprime: no prime found");
		return;
	}
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
