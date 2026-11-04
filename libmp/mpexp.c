#include "os.h"
#include <mp.h>
#include "dat.h"

// res = b**e
//
// knuth, vol 2, pp 398-400
//
// An odd modulus (every one cryptography uses: RSA, Diffie-Hellman,
// ElGamal, DSA) takes Montgomery multiplication with a fixed window of
// the exponent: no division in the loop, and a fifth to a sixth of the
// multiplications.  It is also constant time in the exponent, which is
// the secret (a private key, a Diffie-Hellman x): the same squarings
// and multiplications whatever its bits, each window's multiplier taken
// from the table by reading every entry under a mask, and Montgomery's
// final subtraction made under a mask too.  Only the exponent's length
// (mpsignif) chooses the work, as it must.
//
// The plain square and multiply below remains for an even modulus or
// none.

typedef uvlong mpdbl;		// holds a digit times a digit plus two digits

static void mpexpplain(mpint*, mpint*, mpint*, mpint*);

// x, as far as the optimizer can tell, any value: a mask made from a
// bit goes through it, or clang turns the masked select back into a
// branch on the bit (as in libsec/ecc.c)
static mpdigit
barrier(mpdigit x)
{
#if defined(__GNUC__) || defined(__clang__)
	__asm__("" : "+r"(x));
	return x;
#else
	volatile mpdigit v;

	v = x;
	return v;
#endif
}

// -n0^-1 mod 2^Dbits, for odd n0 (Newton: each step doubles the bits)
static mpdigit
montinv(mpdigit n0)
{
	mpdigit x;
	int i;

	x = n0;			// right to 3 bits: n0*n0 = 1 mod 8
	for(i = 0; i < 5; i++)
		x *= 2 - n0*x;	// 6, 12, 24, 48, 96 bits
	return -x;
}

// r = a*b/R mod m, R = 2^(Dbits*n), for a, b < m (CIOS: Koc, Acar,
// Kaliski, "Analyzing and comparing Montgomery multiplication
// algorithms", 1996).  t has n+2 digits; r may be a or b.  No branch
// or address depends on a digit.
static void
montmul(mpdigit *a, mpdigit *b, mpdigit *m, int n, mpdigit minv, mpdigit *t, mpdigit *r)
{
	int i, j;
	mpdigit u, mask, borrow;
	mpdbl c;

	memset(t, 0, (n+2)*Dbytes);
	for(i = 0; i < n; i++){
		c = 0;
		for(j = 0; j < n; j++){
			c += (mpdbl)a[j]*b[i] + t[j];
			t[j] = (mpdigit)c;
			c >>= Dbits;
		}
		c += t[n];
		t[n] = (mpdigit)c;
		t[n+1] = (mpdigit)(c >> Dbits);

		u = t[0]*minv;
		c = (mpdbl)u*m[0] + t[0];
		c >>= Dbits;
		for(j = 1; j < n; j++){
			c += (mpdbl)u*m[j] + t[j];
			t[j-1] = (mpdigit)c;
			c >>= Dbits;
		}
		c += t[n];
		t[n-1] = (mpdigit)c;
		t[n] = t[n+1] + (mpdigit)(c >> Dbits);
	}

	// t < 2m: r = t - m if that does not borrow, else t
	borrow = 0;
	for(j = 0; j < n; j++){
		c = (mpdbl)t[j] - m[j] - borrow;
		r[j] = (mpdigit)c;
		borrow = (mpdigit)(c >> Dbits) & 1;
	}
	borrow = (mpdigit)(((mpdbl)t[n] - borrow) >> Dbits) & 1;
	mask = barrier(-borrow);	// all ones: t < m, keep t
	for(j = 0; j < n; j++)
		r[j] = (t[j] & mask) | (r[j] & ~mask);
}

// all ones if x == y, else zero, without a branch
static mpdigit
cteq(mpdigit x, mpdigit y)
{
	mpdigit d;

	d = x ^ y;
	return barrier(((d | -d) >> (Dbits-1)) - 1);
}

// r = tab[k], reading every entry
static void
ctlookup(mpdigit *tab, int nent, int n, mpdigit k, mpdigit *r)
{
	int i, j;
	mpdigit mask;

	memset(r, 0, n*Dbytes);
	for(i = 0; i < nent; i++){
		mask = cteq(i, k);
		for(j = 0; j < n; j++)
			r[j] |= tab[i*n + j] & mask;
	}
}

// w bits of e from bit pos up (bits past its top are 0)
static mpdigit
ebits(mpint *e, int pos, int w)
{
	int d, s;
	mpdigit v;

	d = pos/Dbits;
	s = pos%Dbits;
	v = 0;
	if(d < e->top)
		v = e->p[d] >> s;
	if(s+w > Dbits && d+1 < e->top)
		v |= e->p[d+1] << (Dbits-s);
	return v & (((mpdigit)1<<w) - 1);
}

// the window costing least: 2^w-2 multiplications for the table, one
// for each of nbits/w windows (the squarings are nbits whatever w)
static int
windowbits(int nbits)
{
	int w, best, cost, bestcost;

	best = 1;
	bestcost = nbits;
	for(w = 2; w <= 6; w++){
		cost = (1<<w) - 2 + (nbits + w - 1)/w;
		if(cost < bestcost){
			best = w;
			bestcost = cost;
		}
	}
	return best;
}

// mp in Montgomery form, n digits: b*R mod m
static void
tomont(mpint *b, mpint *m, int n, mpdigit *r)
{
	mpint *t;
	int i;

	t = mpnew((n+1)*Dbits);
	mpmod(b, m, t);
	mpleft(t, n*Dbits, t);
	mpmod(t, m, t);
	for(i = 0; i < n; i++)
		r[i] = i < t->top ? t->p[i] : 0;
	memset(t->p, 0, t->size*Dbytes);
	mpfree(t);
}

static void
zerofree(mpdigit *p, int n)
{
	volatile mpdigit *v;

	for(v = p; n > 0; n--)
		*v++ = 0;
	free(p);
}

static void
mpexpmont(mpint *b, mpint *e, mpint *m, mpint *res)
{
	mpdigit *buf, *tab, *acc, *x, *t, *mm, minv, k;
	int n, nbits, w, nent, nwin, i, j;

	n = m->top;
	nbits = mpsignif(e);
	w = windowbits(nbits);
	nent = 1<<w;

	buf = mallocz((nent*n + 4*n + 2)*Dbytes, 1);
	if(buf == nil)
		sysfatal("mpexp: %r");
	tab = buf;
	acc = tab + nent*n;
	x = acc + n;
	mm = x + n;
	t = mm + n;
	memmove(mm, m->p, n*Dbytes);	// res may be m
	minv = montinv(mm[0]);

	// tab[i] = b^i in Montgomery form
	tomont(mpone, m, n, tab);
	tomont(b, m, n, tab + n);
	for(i = 2; i < nent; i++)
		montmul(tab + (i-1)*n, tab + n, mm, n, minv, t, tab + i*n);

	// the windows, top first; the top one holds what is left over
	nwin = (nbits + w - 1)/w;
	k = ebits(e, (nwin-1)*w, w);
	ctlookup(tab, nent, n, k, acc);
	for(i = nwin-2; i >= 0; i--){
		for(j = 0; j < w; j++)
			montmul(acc, acc, mm, n, minv, t, acc);
		ctlookup(tab, nent, n, ebits(e, i*w, w), x);
		montmul(acc, x, mm, n, minv, t, acc);
	}

	// out of Montgomery form: acc*1/R
	memset(x, 0, n*Dbytes);
	x[0] = 1;
	montmul(acc, x, mm, n, minv, t, acc);

	mpbits(res, n*Dbits);
	memmove(res->p, acc, n*Dbytes);
	res->top = n;
	res->sign = 1;
	mpnorm(res);
	zerofree(buf, nent*n + 4*n + 2);
}

void
mpexp(mpint *b, mpint *e, mpint *m, mpint *res)
{
	if(m != nil && m->sign > 0 && m->top > 0 && (m->p[0] & 1)
	&& sizeof(mpdigit)*2 <= sizeof(mpdbl) && mpcmp(e, mpzero) > 0){
		mpexpmont(b, e, m, res);
		return;
	}
	mpexpplain(b, e, m, res);
}

enum {
	Freeb=	0x1,
	Freee=	0x2,
	Freem=	0x4,
};

//int expdebug;

// square and multiply, reducing by division: for an even modulus or
// none, which Montgomery's reduction cannot take
static void
mpexpplain(mpint *b, mpint *e, mpint *m, mpint *res)
{
	mpint *t[2];
	int tofree;
	mpdigit d, bit;
	int i, j;

	i = mpcmp(e,mpzero);
	if(i==0){
		mpassign(mpone, res);
		return;
	}
	if(i<0)
		sysfatal("mpexp: negative exponent");

	t[0] = mpcopy(b);
	t[1] = res;

	tofree = 0;
	if(res == b){
		b = mpcopy(b);
		tofree |= Freeb;
	}
	if(res == e){
		e = mpcopy(e);
		tofree |= Freee;
	}
	if(res == m){
		m = mpcopy(m);
		tofree |= Freem;
	}

	// skip first bit
	i = e->top-1;
	d = e->p[i];
	for(bit = mpdighi; (bit & d) == 0; bit >>= 1)
		;
	bit >>= 1;

	j = 0;
	for(;;){
		for(; bit != 0; bit >>= 1){
			mpmul(t[j], t[j], t[j^1]);
			if(bit & d)
				mpmul(t[j^1], b, t[j]);
			else
				j ^= 1;
			if(m != nil && t[j]->top > m->top){
				mpmod(t[j], m, t[j^1]);
				j ^= 1;
			}
		}
		if(--i < 0)
			break;
		bit = mpdighi;
		d = e->p[i];
	}
	if(m != nil){
		mpmod(t[j], m, t[j^1]);
		j ^= 1;
	}
	if(t[j] == res){
		mpfree(t[j^1]);
	} else {
		mpassign(t[j], res);
		mpfree(t[j]);
	}

	if(tofree){
		if(tofree & Freeb)
			mpfree(b);
		if(tofree & Freee)
			mpfree(e);
		if(tofree & Freem)
			mpfree(m);
	}
}
