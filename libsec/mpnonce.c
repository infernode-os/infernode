/*
 * nonce.c's generator for the numbers libmp holds: DSA's and ElGamal's
 * nonces.
 */
#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * A number's bytes, big-endian, n of them, with no step that depends
 * on its value: mptobe leaves out leading zero bytes, which says how
 * many a secret has.
 */
static void
tooctets(mpint *b, uchar *p, int n)
{
	int i, d;

	for(i = 0; i < n; i++){
		d = i/Dbytes;
		p[n-1-i] = d < b->top? b->p[d] >> (8*(i%Dbytes)): 0;
	}
}

/*
 * The generator for the key x, the message m (its digest, as the
 * number the signature is made of) and numbers below q.
 */
int
mpnoncestart(Noncestate *s, mpint *x, mpint *m, mpint *q, uchar *extra, int nextra)
{
	mpint *h;
	uchar *buf;
	int qlen, rlen;

	qlen = mpsignif(q);
	if(qlen < 2 || q->sign < 0){
		werrstr("nonce: no order");
		return -1;
	}
	rlen = (qlen+7)/8;
	buf = malloc(2*rlen);
	if(buf == nil)
		return -1;
	h = mpnew(0);
	mpmod(m, q, h);
	tooctets(x, buf, rlen);
	tooctets(h, buf+rlen, rlen);
	noncestart(s, noncehlen(qlen), buf, rlen, buf+rlen, rlen, extra, nextra);
	mpfree(h);
	secureZero(buf, 2*rlen);
	free(buf);
	return 0;
}

/*
 * The next candidate into k, which keeps q's length whatever its value
 * (it is not normalized: its top digits may be zero, which mpexp and
 * mpmuladdmod take, and no step then says how long it is).  Returns 1
 * if it is from 1 to q-1, 0 if not, -1 for want of memory.  A candidate
 * out of range is dropped, and says nothing about the one kept: that
 * decision is the one thing here that follows the candidate.
 */
int
mpnoncenext(Noncestate *s, mpint *q, mpint *k)
{
	uchar *t, *qb;
	int qlen, rlen, shift, i, d, nd;
	uint borrow, nz, c;

	qlen = mpsignif(q);
	rlen = (qlen+7)/8;
	t = malloc(2*rlen);
	if(t == nil)
		return -1;
	qb = t + rlen;
	noncenext(s, t, rlen);
	// bits2int: the leftmost qlen bits
	shift = 8*rlen - qlen;
	if(shift > 0){
		c = 0;
		for(i = 0; i < rlen; i++){
			d = t[i];
			t[i] = c<<(8-shift) | d>>shift;
			c = d & ((1<<shift)-1);
		}
	}
	// 0 < t < q, every byte looked at
	tooctets(q, qb, rlen);
	borrow = 0;
	nz = 0;
	for(i = rlen-1; i >= 0; i--){
		borrow = ((uint)t[i] - qb[i] - borrow) >> 31;
		nz |= t[i];
	}
	nd = (rlen + Dbytes-1)/Dbytes;
	mpbits(k, nd*Dbits);
	k->top = nd;
	k->sign = 1;
	for(i = 0; i < nd; i++)
		k->p[i] = 0;
	for(i = 0; i < rlen; i++)
		k->p[i/Dbytes] |= (mpdigit)t[rlen-1-i] << (8*(i%Dbytes));
	secureZero(t, rlen);
	free(t);
	return (int)(borrow & ((nz | (0-nz)) >> 31));
}
