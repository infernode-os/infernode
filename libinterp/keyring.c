#include "lib9.h"
#include "kernel.h"
#include <isa.h>
#include "interp.h"
#include <mp.h>
#include <libsec.h>
#include "pool.h"
#include "raise.h"

/* arguably limbo -t should qualify type name */
#define	DigestState_copy Keyring_DigestState_copy
#define	IPint_random Keyring_IPint_random
#include "keyringif.h"
#include "keyring.h"

#include "ipint.h"
#include "../libkeyring/keys.h"

extern int	upkilled(void);	/* is this Prog being killed (the kernels' dis.c)? */

static Type*	TDigestState;
static Type*	TAESstate;
static Type*	TAESGCMstate;
static Type*	TChaChastate;
static Type*	TECpoint;
static Type*	TRC4state;

static Type*	TSigAlg;
static Type*	TCertificate;
static Type*	TSK;
static Type*	TPK;
static Type*	TAuthinfo;

static Type*	TDSAsk;
static Type*	TDSApk;
static Type*	TDSAsig;
static Type*	TEGsk;
static Type*	TEGpk;
static Type*	TEGsig;
static Type*	TRSAsk;
static Type*	TRSApk;
static Type*	TRSAsig;

enum {
	/*
	 * The longest message getmsg and sendmsg carry, and getstring,
	 * putstring and the byte-array forms: what holds the text of the
	 * largest certificate of the algorithms offered.  That is an
	 * SLH-DSA-256s one: 29792 bytes of signature are 39724 characters
	 * of base 64, after under 300 of algorithm, hash, signer and
	 * expiry; Maxbuf (48K), which certtostr and its fellows already
	 * write such text into, leaves it 9K of room.  It was 4096, less
	 * than an ML-DSA-87 certificate's 6197, and what was longer was
	 * cut with nothing said.
	 */
	Maxmsg=	Maxbuf-1,
	/*
	 * getmsg's header is four digits and a newline, which count to
	 * 9999; a longer message has its length in five or six
	 */
	Maxshorthdr=	9999,
	/*
	 * putstring's messages are one write on a channel that keeps a
	 * write's bounds, a first byte saying whether data or an error;
	 * up to this much, as ever, and a longer one in the long form
	 */
	Shortbuf=	4096,
	Longhdr=	5,	/* 01, and a length of four bytes */
	Maxdhbits=	1<<15,	/* a Diffie-Hellman modulus auth will use */
};

static char Etoolong[] = "message too long";

/* keyring.m tells programs the limit */
typedef char maxmsgcheck[Maxmsg == Keyring_Maxmsg? 1: -1];

static uchar DigestStatemap[] = Keyring_DigestState_map;
static uchar AESstatemap[] = Keyring_AESstate_map;
static uchar AESGCMstatemap[] = Keyring_AESGCMstate_map;
static uchar ChaChastatemap[] = Keyring_ChaChastate_map;
static uchar ECpointmap[] = Keyring_ECpoint_map;
static uchar RC4statemap[] = Keyring_RC4state_map;

static uchar SigAlgmap[] = Keyring_SigAlg_map;
static uchar SKmap[] = Keyring_SK_map;
static uchar PKmap[] = Keyring_PK_map;
static uchar Certificatemap[] = Keyring_Certificate_map;
static uchar Authinfomap[] = Keyring_Authinfo_map;
static uchar DSAskmap[] = Keyring_DSAsk_map;
static uchar DSApkmap[] = Keyring_DSApk_map;
static uchar DSAsigmap[] = Keyring_DSAsig_map;
static uchar EGskmap[] = Keyring_EGsk_map;
static uchar EGpkmap[] = Keyring_EGpk_map;
static uchar EGsigmap[] = Keyring_EGsig_map;
static uchar RSAskmap[] = Keyring_RSAsk_map;
static uchar RSApkmap[] = Keyring_RSApk_map;
static uchar RSAsigmap[] = Keyring_RSAsig_map;

static	PK*	checkPK(Keyring_PK *k);

extern void		setid(char*, int);
extern vlong		osusectime(void);
extern void		freeIPint(Heap*, int);

static char exBadSA[]	= "bad signature algorithm";
static char exBadSK[]	= "bad secret key";
static char exBadPK[]	= "bad public key";
static char exBadCert[]	= "bad certificate";
static char exBadKey[]	= "bad encryption key";
static char exBadDigest[]	= "bad digest value";
static char exBadIvec[]	= "bad ivec";
static char exBadState[] = "bad encryption state";
static char exBadBits[] = "bad key size";

/*
 * The size of a key, a prime or a random number is a program's, and was
 * given to libsec as it came. Below the least each generator can make
 * it never returned: probably_prime looked for ever for a witness for
 * 3, which every small search meets, and RSAsk.gen and EGsk.gen ask
 * again until the result has the bits asked for, which five bits of
 * modulus never has. That was after release(), so the Prog could not be
 * killed, and went on using a processor until the emulator ended. At
 * none or less genprime wrote before its number. Very large ones
 * overflow libmp's digit counts, or take longer than anyone will wait.
 */
enum
{
	MinRSAbits	= 16,	/* as libkeyring's rsa_gen: two primes of eight bits */
	MinDHbits	= 3,	/* the least safe prime is 7 */
	Maxgenbits	= 1<<16,
	Maxrandbits	= 1<<26,	/* as IPint's shifts: 8MB of number */
};

static void
genbits(int n, int min, int max)
{
	if(n < min || n > max)
		error(exBadBits);
}

/* convert a Big to base64 ascii */
int
bigtobase64(mpint* b, char *buf, int len)
{
	uchar *p;
	int n, rv, o;

	n = (b->top+1)*Dbytes;
	p = malloc(n+1);
	if(p == nil)
		goto Err;
	n = mptobe(b, p+1, n, nil);
	if(n < 0)
		goto Err;
	p[0] = 0;
	if(n != 0 && (p[1]&0x80)){
		/* force leading 0 byte for compatibility with older representation */
		/* TO DO: if b->sign < 0, complement bits and add one */
		o = 0;
		n++;
	}else
		o = 1;
	rv = enc64(buf, len, p+o, n);
	free(p);
	return rv;

Err:
	free(p);
	if(len > 0){
		*buf = '*';
		return 1;
	}
	return 0;
}

/* convert a Big to base64 ascii for %U */
int
big64conv(Fmt *f)
{
	mpint *b;
	char *buf;
	int n;

	b = va_arg(f->args, mpint*);
	n = (b->top+1)*Dbytes + 1;
	n = ((n+3)/3)*4 + 1;
	buf = malloc(n);
	if(buf == nil)
		return fmtstrcpy(f, "<nomem>");
	bigtobase64(b, buf, n);
	n = fmtstrcpy(f, buf);
	free(buf);
	return  n;
}

static void*
newthing(Type *t, int add)
{
	Heap *h;

	h = heap(t);
	if(add)
		ptradd(h);
	return H2D(void*, h);
}

/*
 * What a builtin goes on using while the VM is let go.  Its arguments
 * are the call's (the frame holds them, and no other Prog reaches the
 * frame), but what they refer to is not: a key adt's numbers, and an
 * Authinfo's keys, are fields any Prog with the adt can assign, and an
 * assignment frees what was there, under an exponentiation that takes
 * milliseconds or a signature that takes seconds; and the place a
 * result goes to (*f->ret) is the caller's, so a result stored there
 * early and written to after the VM comes back relies on the caller
 * (compiled Limbo has results land in its frame; a module made by hand
 * can name a variable other threads assign).  keep hangs an array on
 * one of the call's own pointer arguments, with the argument's value in
 * its first place and n more for what must last: the frame is a root
 * for the collector while the call runs, and unwinds with it if
 * something raises.  unkeep puts the argument back.
 * (libinterp/ipint.c's hold is the same device.)
 */
static void**
keep(void *slot, int n)
{
	void **arg, **k;
	Array *a;

	arg = slot;
	a = H2D(Array*, heaparray(&Tptr, n+1));
	k = (void**)a->data;
	k[0] = *arg;
	if(k[0] != H)
		Setmark(D2H(k[0]));
	*arg = a;
	return k;
}

/* another reference to v, something of the heap's, in k[i] */
static void*
keepref(void **k, int i, void *v)
{
	Heap *h;

	if(v != H && v != nil){
		h = D2H(v);
		h->ref++;
		Setmark(h);
		k[i] = v;
	}
	return v;
}

static void
unkeep(void *slot)
{
	void **arg, **k;
	Array *a;

	arg = slot;
	a = *arg;
	k = (void**)a->data;
	*arg = k[0];
	if(k[0] != H)
		Setmark(D2H(k[0]));
	k[0] = H;
	destroy(a);
}

/*
 * v, kept until now, as it is stored where a result goes.  The collector
 * may have looked there already this round and not yet at the array v
 * was kept in, which is about to go: unmarked for a round, v's parts
 * would be swept the next before v was reached again.
 */
static void*
kept(void *v)
{
	if(v != H)
		Setmark(D2H(v));
	return v;
}

/*
 * Something of C's (a key or signature libsec made) that is the
 * collector's to free: what is made from it afterwards (the adt's
 * cells, copies of its numbers) can raise for want of heap, and the
 * raise left it held by nothing.  The cell is made without a raise
 * (with no room the thing is freed first); nothing refers to it, the VM
 * is held until it is destroyed, and if a raise goes by, the sweep
 * frees it and what it holds.
 */
typedef struct Cres Cres;
struct Cres
{
	void	*p;
	void	(*free)(void*);
};
static Type*	TCres;

static void
freeCres(Heap *h, int swept)
{
	Cres *c;

	c = H2D(Cres*, h);
	if(c->p != nil)
		(*c->free)(c->p);
	freeheap(h, swept);
}

static Cres*
cres(void *p, void (*fr)(void*))
{
	Heap *h;
	Cres *c;

	h = nheapok(sizeof(Cres));
	if(h == nil){
		(*fr)(p);
		error(exHeap);
	}
	h->t = TCres;
	TCres->ref++;
	c = H2D(Cres*, h);
	c->p = p;
	c->free = fr;
	return c;
}

static Keyring_IPint*
ipcopymp(mpint* b)
{
	if(b == nil)
		return H;
	return newIPint(mpcopy(b));
}

/* convert a base64 string to a big */
mpint*
base64tobig(char *str, char **strp)
{
	int n;
	char *p;
	mpint *b;
	uchar hex[(MaxBigBytes*6 + 7)/8];

	for(p = str; *p && *p != '\n'; p++)
		;
	/*
	 * where the field ended, whether or not it held a number: callers
	 * parse a key as one call after another, each starting where the
	 * last stopped (base64tobig(p, &p)).  An empty field returned nil
	 * with *strp untouched, and the next call started from whatever
	 * the caller's stack held: a key string that is just a newline,
	 * which a peer sends, read from a wild pointer.
	 */
	if(strp){
		if(*p)
			*strp = p+1;
		else
			*strp = p;
	}
	if(p == str)
		return nil;
	n = dec64(hex, sizeof(hex), str, p - str);
	if(n <= 0)
		return nil;	/* no base64 in it */
	b = betomp(hex, n, nil);
	/*
	 * a zero as libmp knows one: betomp leaves a number of all zero
	 * bytes with a digit in it, which compares greater than mpzero and
	 * is not the divisor mpdiv looks for
	 */
	mpnorm(b);
	return b;
}

/*
 *  signature algorithms
 */
enum
{
	Maxalg = 8
};
static SigAlgVec	*algs[Maxalg];
static int		nalg;

static SigAlg*
newSigAlg(SigAlgVec *vec)
{
	Heap *h;
	SigAlg *sa;

	h = heap(TSigAlg);
	sa = H2D(SigAlg*, h);
	retstr(vec->name, &sa->x.name);
	sa->vec = vec;
	return sa;
}

static void
freeSigAlg(Heap *h, int swept)
{
	if(!swept)
		freeheap(h, 0);
}

SigAlgVec*
findsigalg(char *name)
{
	SigAlgVec **sap;

	for(sap = algs; sap < &algs[nalg]; sap++)
		if(strcmp(name, (*sap)->name) == 0)
			return *sap;
	return nil;
}

SigAlg*
strtoalg(char *str, char **strp)
{
	int n;
	char *p, name[20];
	SigAlgVec *sa;


	p = strchr(str, '\n');
	if(p == 0){
		p = str + strlen(str);
		if(strp)
			*strp = p;
	} else {
		if(strp)
			*strp = p+1;
	}

	n = p - str;
	if(n < sizeof(name)){
		strncpy(name, str, n);
		name[n] = 0;
		sa = findsigalg(name);
		if(sa != nil)
			return newSigAlg(sa);
	}
	return nil;
}

/*
 * A SigAlg is an adt of the module's interface, and a key's or a
 * certificate's sa is a field a program can assign: nil, a SigAlg it
 * made itself (ref SigAlg("rsa"): a string and nothing after it), or
 * another key's. None of that was looked for: the vector was read from
 * beyond the program's eight bytes or through nil.
 */
static SigAlg*
checkSigAlg(Keyring_SigAlg *ksa)
{
	SigAlgVec **sap;
	SigAlg *sa;

	sa = (SigAlg*)ksa;
	if(sa == H || sa == nil || D2H(sa)->t != TSigAlg)
		errorf("%s: %s", exType, exBadSA);
	for(sap = algs; sap < &algs[nalg]; sap++)
		if(sa->vec == *sap)
			return sa;
	errorf("%s: %s", exType, exBadSA);
	return nil;
}

/*
 * Whether sa is still the algorithm a key or signature was made by,
 * which vec records. The functions that read a key were found through
 * its sa, so a key relabelled with another's (sk.sa = other.sa) had one
 * algorithm's code read the other's structure: an RSA key printed as
 * Ed25519 gave the addresses of its numbers, an Ed25519 key signed as
 * RSA used its bytes as pointers. A key that says it is not what it is
 * is refused, and what is done with a key is found from vec, which no
 * program can change (nor another thread, while a builtin has let the
 * VM go).
 */
static int
ownalg(Keyring_SigAlg *ksa, SigAlgVec *vec)
{
	SigAlg *sa;

	sa = (SigAlg*)ksa;
	return vec != nil && sa != H && sa != nil && D2H(sa)->t == TSigAlg && sa->vec == vec;
}

/*
 *  parse next new line terminated string into a String
 */
String*
strtostring(char *str, char **strp)
{
	char *p;
	String *s;

	p = strchr(str, '\n');
	if(p == 0)
		p = str + strlen(str);
	s = H;
	retnstr(str, p - str, &s);

	if(strp){
		if(*p)
			p++;
		*strp = p;
	}

	return s;
}

/*
 *  private part of a key
 */
static SK*
newSK(SigAlg *sa, String *owner, int increfsa)
{
	Heap *h;
	SK *k;

	h = heap(TSK);
	k = H2D(SK*, h);
	k->x.sa = (Keyring_SigAlg*)sa;
	if(increfsa) {
		h = D2H(sa);
		h->ref++;
		Setmark(h);
	}
	k->x.owner = owner;
	k->key = 0;
	k->vec = sa->vec;
	return k;
}

static void
freeSK(Heap *h, int swept)
{
	SK *k;

	k = H2D(SK*, h);
	if(k->key != nil && k->vec != nil)
		(*k->vec->skfree)(k->key);
	freeheap(h, swept);
}

static SK*
checkSK(Keyring_SK *k)
{
	SK *sk;

	sk = (SK*)k;
	/* the type first: key is not a field of an SK a program made (ref SK(sa, owner)) */
	if(sk == H || sk == nil || D2H(sk)->t != TSK || sk->key == 0 || !ownalg(sk->x.sa, sk->vec)){
		errorf("%s: %s", exType, exBadSK);
		return nil;
	}
	return sk;
}

void
Keyring_genSK(void *fp)
{
	F_Keyring_genSK *f;
	SK *sk;
	SigAlg *sa;
	SigAlgVec *vec;
	void *v, *key, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sa = strtoalg(string2c(f->algname), 0);
	if(sa == nil)
		return;

	/* the key is the call's until it is whole: see keep */
	sk = newSK(sa, stringdup(f->owner), 0);
	k = keep(&f->owner, 1);
	k[1] = sk;
	vec = sk->vec;
	release();
	key = (*vec->gensk)(f->length);
	acquire();
	sk->key = key;
	/*
	 * gensk returns nil when key generation fails (e.g. an invalid key
	 * size).  Honour genSK's contract by returning nil rather than an SK
	 * with a nil internal key, which would otherwise trip exBadSK only on
	 * later use.
	 */
	if(key == nil){
		unkeep(&f->owner);
		return;
	}
	k[1] = H;
	unkeep(&f->owner);
	*f->ret = kept(sk);
}

void
Keyring_genSKfromPK(void *fp)
{
	F_Keyring_genSKfromPK *f;
	SigAlg *sa;
	SigAlgVec *vec;
	PK *pk;
	SK *sk;
	void *v, *key, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	pk = checkPK(f->pk);
	sa = checkSigAlg(pk->x.sa);
	sk = newSK(sa, stringdup(f->owner), 1);
	k = keep(&f->pk, 1);
	k[1] = sk;
	vec = sk->vec;
	release();
	key = (*vec->genskfrompk)(pk->key);
	acquire();
	sk->key = key;
	/* as genSK: nil for a key that cannot be made, not an SK with none */
	if(key == nil){
		unkeep(&f->pk);
		return;
	}
	k[1] = H;
	unkeep(&f->pk);
	*f->ret = kept(sk);
}

/* converts a sequence of newline-separated base64-encoded mpints to attr=hexval ... in f */
static char*
bigs2attr(Fmt *f, char *bigs, char **names)
{
	int i, n, nd;
	char *b16, *vals[20];
	uchar data[(MaxBigBytes*6 + 7)/8];

	b16 = malloc(2*MaxBigBytes+1);
	if(b16 == nil)
		return nil;
	n = getfields(bigs, vals, nelem(vals), 0, "\n");
	for(i = 0; i < n-1; i++){
		if(names == nil || names[i] == nil)
			break;	/* shouldn't happen */
		nd = dec64(data, sizeof(data), vals[i], strlen(vals[i]));
		if(nd < 0)
			break;
		enc16(b16, 2*MaxBigBytes+1, data, nd);
		fmtprint(f, " %s=%s", names[i], b16);
	}
	free(b16);
	return fmtstrflush(f);
}

void
Keyring_sktoattr(void *fp)
{
	F_Keyring_sktoattr *f;
	char *val, *buf, *owner;
	Fmt o;
	SK *sk;

	f = fp;
	sk = checkSK(f->sk);
	buf = malloc(Maxbuf);
	if(buf == nil){
		retstr(nil, f->ret);
		return;
	}
	(*sk->vec->sk2str)(sk->key, buf, Maxbuf);
	fmtstrinit(&o);
	fmtprint(&o, "alg=%q", sk->vec->name);
	owner = string2c(sk->x.owner);
	if(*owner)
		fmtprint(&o, " owner=%q", owner);
	val = bigs2attr(&o, buf, sk->vec->skattr);
	free(buf);
	retstr(val, f->ret);
	free(val);
}

static int
sktostr(SK *sk, char *buf, int len)
{
	int n;

	n = snprint(buf, len, "%s\n%s\n", sk->vec->name, string2c(sk->x.owner));
	return n + (*sk->vec->sk2str)(sk->key, buf+n, len - n);
}

/*
 * A key's or certificate's text, for sktostr, pktostr and certtostr.
 * Each allocated its 48K with malloc and then looked at its argument:
 * sktostr(nil) raised with the buffer never freed, two thousand calls
 * took the kernel's main pool 96MB, and with the pool at its limit
 * nothing else in the emulator could have 48K again. The argument is
 * now checked first, and the text is made in an array of the Dis heap:
 * making the string of it can raise for want of heap, and an array
 * nothing refers to is the collector's to free.
 */
static Array*
textbuf(void)
{
	return H2D(Array*, heaparray(&Tbyte, Maxbuf));
}

static void
rettext(Array *a, String **ret)
{
	retstr((char*)a->data, ret);
	memset(a->data, 0, a->len);	/* it may be a secret key */
	destroy(a);
}

void
Keyring_sktostr(void *fp)
{
	F_Keyring_sktostr *f;
	SK *sk;
	Array *a;

	f = fp;
	sk = checkSK(f->sk);
	a = textbuf();
	sktostr(sk, (char*)a->data, Maxbuf);
	rettext(a, f->ret);
}

static SK*
strtosk(char *buf)
{
	SK *sk;
	char *p;
	SigAlg *sa;
	String *owner;
	void *key;

	sa = strtoalg(buf, &p);
	if(sa == nil)
		return H;
	owner = strtostring(p, &p);
	if(owner == H){
		destroy(sa);
		return H;
	}

	key = (*sa->vec->str2sk)(p, &p);
	if(key == nil){
		destroy(sa);
		destroy(owner);
		return H;
	}
	sk = newSK(sa, owner, 0);
	sk->key = key;

	return sk;
}

void
Keyring_strtosk(void *fp)
{
	F_Keyring_strtosk *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);
	*f->ret = (Keyring_SK*)strtosk(string2c(f->s));
}

/*
 *  public part of a key
 */
PK*
newPK(SigAlg *sa, String *owner, int increfsa)
{
	Heap *h;
	PK *k;

	h = heap(TPK);
	k = H2D(PK*, h);
	k->x.sa = (Keyring_SigAlg*)sa;
	if(increfsa) {
		h = D2H(sa);
		h->ref++;
		Setmark(h);
	}
	k->x.owner = owner;
	k->key = 0;
	k->vec = sa->vec;
	return k;
}

void
pkimmutable(PK *k)
{
	poolimmutable(D2H(k));
	poolimmutable(D2H(k->x.sa));
	poolimmutable(D2H(k->x.sa->name));
	poolimmutable(D2H(k->x.owner));
}

void
pkmutable(PK *k)
{
	poolmutable(D2H(k));
	poolmutable(D2H(k->x.sa));
	poolmutable(D2H(k->x.sa->name));
	poolmutable(D2H(k->x.owner));
}

void
freePK(Heap *h, int swept)
{
	PK *k;

	k = H2D(PK*, h);
	if(k->key != nil && k->vec != nil)
		(*k->vec->pkfree)(k->key);
	freeheap(h, swept);
}

static PK*
checkPK(Keyring_PK *k)
{
	PK *pk;

	pk = (PK*)k;
	if(pk == H || pk == nil || D2H(pk)->t != TPK || pk->key == 0 || !ownalg(pk->x.sa, pk->vec)){
		errorf("%s: %s", exType, exBadPK);
		return nil;
	}
	return pk;
}

void
Keyring_sktopk(void *fp)
{
	F_Keyring_sktopk *f;
	PK *pk;
	SigAlg *sa;
	SK *sk;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	sk = checkSK(f->sk);
	sa = checkSigAlg(sk->x.sa);
	pk = newPK(sa, stringdup(sk->x.owner), 1);
	pk->key = (*sk->vec->sk2pk)(sk->key);
	*f->ret = (Keyring_PK*)pk;
}

static int
pktostr(PK *pk, char *buf, int len)
{
	int n;

	n = snprint(buf, len, "%s\n%s\n", pk->vec->name, string2c(pk->x.owner));
	return n + (*pk->vec->pk2str)(pk->key, buf+n, len - n);
}

void
Keyring_pktostr(void *fp)
{
	F_Keyring_pktostr *f;
	PK *pk;
	Array *a;

	f = fp;
	pk = checkPK(f->pk);
	a = textbuf();
	pktostr(pk, (char*)a->data, Maxbuf);
	rettext(a, f->ret);
}

void
Keyring_pktoattr(void *fp)
{
	F_Keyring_pktoattr *f;
	char *val, *buf, *owner;
	Fmt o;
	PK *pk;

	f = fp;
	pk = checkPK(f->pk);
	buf = malloc(Maxbuf);
	if(buf == nil){
		retstr(nil, f->ret);
		return;
	}
	(*pk->vec->pk2str)(pk->key, buf, Maxbuf);
	fmtstrinit(&o);
	fmtprint(&o, "alg=%q", pk->vec->name);
	owner = string2c(pk->x.owner);
	if(*owner)
		fmtprint(&o, " owner=%q", owner);
	val = bigs2attr(&o, buf, pk->vec->pkattr);
	free(buf);
	retstr(val, f->ret);
	free(val);
}

static PK*
strtopk(char *buf)
{
	PK *pk;
	char *p;
	SigAlg *sa;
	String *owner;
	void *key;

	sa = strtoalg(buf, &p);
	if(sa == nil)
		return H;
	owner = strtostring(p, &p);
	if(owner == H){
		destroy(sa);
		return H;
	}

	key = (*sa->vec->str2pk)(p, &p);
	if(key == nil){
		destroy(sa);
		destroy(owner);
		return H;
	}
	pk = newPK(sa, owner, 0);
	pk->key = key;

	return pk;
}

void
Keyring_strtopk(void *fp)
{
	F_Keyring_strtopk *f;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);
	*f->ret = (Keyring_PK*)strtopk(string2c(f->s));
}

/*
 *  Certificates/signatures
 */

void
certimmutable(Certificate *c)
{
	poolimmutable(D2H(c));
	poolimmutable(D2H(c->x.signer));
	poolimmutable(D2H(c->x.ha));
	poolimmutable(D2H(c->x.sa));
	poolimmutable(D2H(c->x.sa->name));
}

void
certmutable(Certificate *c)
{
	poolmutable(D2H(c));
	poolmutable(D2H(c->x.signer));
	poolmutable(D2H(c->x.ha));
	Setmark(D2H(c->x.sa));
	poolmutable(D2H(c->x.sa));
	Setmark(D2H(c->x.sa->name));
	poolmutable(D2H(c->x.sa->name));
}

Certificate*
newCertificate(SigAlg *sa, String *ha, String *signer, long exp, int increfsa)
{
	Heap *h;
	Certificate *c;

	h = heap(TCertificate);
	c = H2D(Certificate*, h);
	c->x.sa = (Keyring_SigAlg*)sa;
	if(increfsa) {
		h = D2H(sa);
		h->ref++;
		Setmark(h);
	}
	c->x.signer = signer;
	c->x.ha = ha;
	c->x.exp = exp;
	c->signa = 0;
	c->vec = sa->vec;

	return c;
}

void
freeCertificate(Heap *h, int swept)
{
	Certificate *c;

	c = H2D(Certificate*, h);
	if(c->signa != nil && c->vec != nil)
		(*c->vec->sigfree)(c->signa);
	freeheap(h, swept);
}

Certificate*
checkCertificate(Keyring_Certificate *c)
{
	Certificate *cert;

	cert = (Certificate*)c;
	if(cert == H || cert == nil || D2H(cert)->t != TCertificate || cert->signa == 0 || !ownalg(cert->x.sa, cert->vec)){
		errorf("%s: %s", exType, exBadCert);
		return nil;
	}
	return cert;
}

static int
certtostr(Certificate *c, char *buf, int len)
{
	int n;

	n = snprint(buf, len, "%s\n%s\n%s\n%d\n", c->vec->name,
		string2c(c->x.ha), string2c(c->x.signer), c->x.exp);
	return n + (*c->vec->sig2str)(c->signa, buf+n, len - n);
}

void
Keyring_certtostr(void *fp)
{
	F_Keyring_certtostr *f;
	Certificate *c;
	Array *a;

	f = fp;
	c = checkCertificate(f->c);
	a = textbuf();
	certtostr(c, (char*)a->data, Maxbuf);
	rettext(a, f->ret);
}

void
Keyring_certtoattr(void *fp)
{
	F_Keyring_certtoattr *f;
	char *val, *buf, *ha;
	Fmt o;
	Certificate *c;

	f = fp;
	c = checkCertificate(f->c);
	buf = malloc(Maxbuf);
	if(buf == nil){
		retstr(nil, f->ret);
		return;
	}
	(*c->vec->sig2str)(c->signa, buf, Maxbuf);
	ha = string2c(c->x.ha);
	if(strcmp(ha, "sha") == 0)
		ha = "sha1";	/* normalise */
	fmtstrinit(&o);
	fmtprint(&o, "sigalg=%q-%q signer=%q expires=%ud", c->vec->name, ha,
		string2c(c->x.signer), c->x.exp);
	val = bigs2attr(&o, buf, c->vec->sigattr);
	free(buf);
	retstr(val, f->ret);
	free(val);
}

static Certificate*
strtocert(char *buf)
{
	Certificate *c;
	char *p;
	SigAlg *sa;
	String *signer, *ha;
	long exp;
	void *signa;

	sa = strtoalg(buf, &p);
	if(sa == 0)
		return H;

	ha = strtostring(p, &p);
	if(ha == H){
		destroy(sa);
		return H;
	}

	signer = strtostring(p, &p);
	if(signer == H){
		destroy(sa);
		destroy(ha);
		return H;
	}

	exp = strtoul(p, &p, 10);
	if(*p)
		p++;
	signa = (*sa->vec->str2sig)(p, &p);
	if(signa == nil){
		destroy(sa);
		destroy(ha);
		destroy(signer);
		return H;
	}

	c = newCertificate(sa, ha, signer, exp, 0);
	c->signa = signa;

	return c;
}

void
Keyring_strtocert(void *fp)
{
	F_Keyring_strtocert *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = (Keyring_Certificate*)strtocert(string2c(f->s));
}

static Certificate*
sign(SK *sk, char *ha, ulong exp, uchar *a, int len)
{
	Certificate *c;
	mpint *b;
	int n;
	SigAlg *sa;
	SigAlgVec *vec;
	DigestState ds0;
	uchar digest[SHA512dlen];
	char *buf;
	String *hastr;
	void *signa;

	/*
	 * the digest's state is this function's: asked to allocate one,
	 * the hash gave nil when it could not, and the second call then
	 * hashed the signer's name and expiry alone, not the data
	 */
	memset(&ds0, 0, sizeof(ds0));
	hastr = H;
	sa = checkSigAlg(sk->x.sa);
	buf = malloc(Maxbuf);
	if(buf == nil)
		return nil;

	/* add signer name and expiration time to hash */
	n = snprint(buf, Maxbuf, "%s %lud", string2c(sk->x.owner), exp);
	if(strcmp(ha, "sha256") == 0){
		sha256(a, len, 0, &ds0);
		sha256((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA256dlen;
	} else if(strcmp(ha, "sha384") == 0){
		sha384(a, len, 0, &ds0);
		sha384((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA384dlen;
	} else if(strcmp(ha, "sha") == 0 || strcmp(ha, "sha1") == 0){
		sha1(a, len, 0, &ds0);
		sha1((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA1dlen;
	} else if(strcmp(ha, "md5") == 0){
		md5(a, len, 0, &ds0);
		md5((uchar*)buf, n, digest, &ds0);
		n = Keyring_MD5dlen;
	} else {
		free(buf);
		return nil;
	}
	free(buf);

	/*
	 * A digest is a number to the algorithms that sign numbers, and
	 * bytes, at their full length, to those that sign bytes: see
	 * SigAlgVec.
	 */
	vec = sk->vec;
	b = nil;
	if(vec->signb == nil){
		b = betomp(digest, n, nil);
		if(b == nil)
			return nil;
	}

	/* sign */
	retstr(ha, &hastr);
	c = newCertificate(sa, hastr, stringdup(sk->x.owner), exp, 1);
	certimmutable(c);		/* hide from the garbage collector */
	release();
	if(vec->signb != nil)
		signa = (*vec->signb)(digest, n, sk->key);
	else
		signa = (*vec->sign)(b, sk->key);
	acquire();
	mpfree(b);
	/*
	 * No signature (no memory for an SLH-DSA signature's parts, ML-DSA
	 * at its loop's bound, an RSA key whose parts do not agree) is no
	 * certificate: one with no signature was returned, and its first
	 * use raised "bad certificate".
	 */
	if(signa == nil){
		certmutable(c);
		destroy(c);
		return nil;
	}
	c->signa = signa;

	return c;
}

void
Keyring_sign(void *fp)
{
	F_Keyring_sign *f;
	Certificate *c;
	mpint *b;
	int n;
	SigAlg *sa;
	SigAlgVec *vec;
	SK *sk;
	XDigestState *ds;
	uchar digest[SHA512dlen];
	char *buf;
	void *v, *signa, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = checkSK(f->sk);
	sa = checkSigAlg(sk->x.sa);

	/* add signer name and expiration time to hash */
	if(f->state == H)
		return;
	/*
	 * A DigestState is an adt of the module's interface, so a program
	 * can make one of its own (ref DigestState(0)): eight bytes, not
	 * libsec's state. It was taken with a cast here and in verify, and
	 * the digest's block buffer, count and length were whatever lay
	 * after it in the heap: the signer's name was copied there.
	 */
	ds = checktype(f->state, TDigestState, "DigestState", 0);
	buf = malloc(Maxbuf);
	if(buf == nil)
		return;
	n = snprint(buf, Maxbuf, "%s %d", string2c(sk->x.owner), f->exp);
	if(strcmp(string2c(f->ha), "sha256") == 0){
		sha256((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA256dlen;
	} else if(strcmp(string2c(f->ha), "sha384") == 0){
		sha384((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA384dlen;
	} else if(strcmp(string2c(f->ha), "sha512") == 0){
		sha512((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA512dlen;
	} else if(strcmp(string2c(f->ha), "sha") == 0 || strcmp(string2c(f->ha), "sha1") == 0){
		sha1((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA1dlen;
	} else if(strcmp(string2c(f->ha), "md5") == 0){
		md5((uchar*)buf, n, digest, &ds->state);
		n = Keyring_MD5dlen;
	} else {
		free(buf);
		return;
	}
	free(buf);

	/*
	 * sign.  The certificate is the call's until it is whole (see
	 * keep): it was put where the result goes first, and filled in
	 * after the VM had been let go for as long as signing takes.
	 */
	vec = sk->vec;
	c = newCertificate(sa, stringdup(f->ha), stringdup(sk->x.owner), f->exp, 1);
	k = keep(&f->sk, 1);
	k[1] = c;
	b = nil;
	if(vec->signb == nil){	/* see sign */
		b = betomp(digest, n, nil);
		if(b == nil){
			unkeep(&f->sk);
			return;
		}
	}
	release();
	if(vec->signb != nil)
		signa = (*vec->signb)(digest, n, sk->key);
	else
		signa = (*vec->sign)(b, sk->key);
	acquire();
	mpfree(b);
	/* no signature made: no certificate (see sign) */
	if(signa == nil){
		unkeep(&f->sk);
		return;
	}
	c->signa = signa;
	k[1] = H;
	unkeep(&f->sk);
	*f->ret = kept(c);
}

void
Keyring_signm(void *fp)
{
	F_Keyring_signm *f;
	Certificate *c;
	mpint *b;
	SigAlg *sa;
	SigAlgVec *vec;
	SK *sk;
	void *v, *signa, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = checkSK(f->sk);
	sa = checkSigAlg(sk->x.sa);

	if(f->m == H)
		return;
	b = checkIPint(f->m);

	/*
	 * sign the number (an algorithm that signs bytes signs the
	 * number's, with no leading zero); m is the call's argument, and
	 * the certificate the call's until it is whole: see Keyring_sign
	 */
	c = newCertificate(sa, stringdup(f->ha), stringdup(sk->x.owner), 0, 1);
	k = keep(&f->sk, 1);
	k[1] = c;
	vec = sk->vec;
	release();
	signa = (*vec->sign)(b, sk->key);
	acquire();
	if(signa == nil){
		unkeep(&f->sk);
		return;
	}
	c->signa = signa;
	k[1] = H;
	unkeep(&f->sk);
	*f->ret = kept(c);
}

static int
verify(PK *pk, Certificate *c, char *a, int len)
{
	mpint *b;
	int n;
	SigAlgVec *vec;
	DigestState ds0;
	uchar digest[SHA512dlen];
	char *buf;

	vec = c->vec;
	if(vec != pk->vec)
		return 0;
	memset(&ds0, 0, sizeof(ds0));	/* see sign */

	/* add signer name and expiration time to hash */
	buf = malloc(Maxbuf);
	if(buf == nil)
		return 0;
	n = snprint(buf, Maxbuf, "%s %d", string2c(c->x.signer), c->x.exp);
	if(strcmp(string2c(c->x.ha), "sha256") == 0){
		sha256((uchar*)a, len, 0, &ds0);
		sha256((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA256dlen;
	} else if(strcmp(string2c(c->x.ha), "sha384") == 0){
		sha384((uchar*)a, len, 0, &ds0);
		sha384((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA384dlen;
	} else if(strcmp(string2c(c->x.ha), "sha512") == 0){
		sha512((uchar*)a, len, 0, &ds0);
		sha512((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA512dlen;
	} else if(strcmp(string2c(c->x.ha), "sha") == 0 || strcmp(string2c(c->x.ha), "sha1") == 0){
		sha1((uchar*)a, len, 0, &ds0);
		sha1((uchar*)buf, n, digest, &ds0);
		n = Keyring_SHA1dlen;
	} else if(strcmp(string2c(c->x.ha), "md5") == 0){
		md5((uchar*)a, len, 0, &ds0);
		md5((uchar*)buf, n, digest, &ds0);
		n = Keyring_MD5dlen;
	} else {
		free(buf);
		return 0;
	}
	free(buf);

	/* verify: the digest as a number or as bytes, as it was signed (see sign) */
	b = nil;
	if(vec->verifyb == nil){
		b = betomp(digest, n, nil);
		if(b == nil)
			return 0;
	}
	release();
	if(vec->verifyb != nil)
		n = (*vec->verifyb)(digest, n, c->signa, pk->key);
	else
		n = (*vec->verify)(b, c->signa, pk->key);
	acquire();

	mpfree(b);
	return n;
}

void
Keyring_verify(void *fp)
{
	F_Keyring_verify *f;
	Certificate *c;
	mpint *b;
	int n;
	SigAlgVec *vec;
	PK *pk;
	XDigestState *ds;
	uchar digest[SHA512dlen];
	char *buf;

	f = fp;
	*f->ret = 0;

	c = checkCertificate(f->cert);
	pk = checkPK(f->pk);
	vec = c->vec;
	if(vec != pk->vec)
		return;

	/* add signer name and expiration time to hash */
	if(f->state == H)
		return;
	ds = checktype(f->state, TDigestState, "DigestState", 0);	/* see Keyring_sign */
	buf = malloc(Maxbuf);
	if(buf == nil)
		return;
	n = snprint(buf, Maxbuf, "%s %d", string2c(c->x.signer), c->x.exp);

	if(strcmp(string2c(c->x.ha), "sha256") == 0){
		sha256((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA256dlen;
	} else if(strcmp(string2c(c->x.ha), "sha384") == 0){
		sha384((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA384dlen;
	} else if(strcmp(string2c(c->x.ha), "sha512") == 0){
		sha512((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA512dlen;
	} else if(strcmp(string2c(c->x.ha), "sha") == 0 || strcmp(string2c(c->x.ha), "sha1") == 0){
		sha1((uchar*)buf, n, digest, &ds->state);
		n = Keyring_SHA1dlen;
	} else if(strcmp(string2c(c->x.ha), "md5") == 0){
		md5((uchar*)buf, n, digest, &ds->state);
		n = Keyring_MD5dlen;
	} else {
		free(buf);
		return;
	}
	free(buf);

	/* verify: see sign */
	b = nil;
	if(vec->verifyb == nil){
		b = betomp(digest, n, nil);
		if(b == nil)
			return;
	}
	release();
	if(vec->verifyb != nil)
		n = (*vec->verifyb)(digest, n, c->signa, pk->key);
	else
		n = (*vec->verify)(b, c->signa, pk->key);
	acquire();
	*f->ret = n;

	mpfree(b);
}

void
Keyring_verifym(void *fp)
{
	F_Keyring_verifym *f;
	Certificate *c;
	SigAlgVec *vec;
	PK *pk;
	mpint *m;
	int n;

	f = fp;
	*f->ret = 0;

	c = checkCertificate(f->cert);
	pk = checkPK(f->pk);
	vec = c->vec;
	if(vec != pk->vec)
		return;

	if(f->m == H)
		return;
	m = checkIPint(f->m);

	release();
	n = (*vec->verify)(m, c->signa, pk->key);
	acquire();
	*f->ret = n;
}

/*
 *  digests
 */
void
Keyring_DigestState_copy(void *fp)
{
	F_DigestState_copy *f;
	Heap *h;
	XDigestState *ds, *ods;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->d != H){
		ods = checktype(f->d, TDigestState, "DigestState", 0);
		h = heap(TDigestState);
		ds = H2D(XDigestState*, h); 	
		memmove(&ds->state, &ods->state, sizeof(ds->state)); 
		*f->ret = (Keyring_DigestState*)ds;
	}
}

/*
 * How many bytes of a program's array a digest is to read: the count is
 * the program's, and only one longer than the array was looked for (and
 * cut down). A negative one went to libsec as an unsigned length: sha1
 * and md5 take whole blocks off it in an int, which stepped back
 * from the array, and hashed up to 63 bytes found before it (a program
 * read the heap below its array a byte at a time, by matching digests);
 * the SHA-2 and SHA-3 digests walked forward to the end of memory. A
 * count that is not within the array is refused, as the ciphers refuse it.
 */
static int
digestcount(Array *buf, int n)
{
	if(n < 0 || n > buf->len)
		error(exBounds);
	return n;
}

static Keyring_DigestState*
keyring_digest_x(Array *buf, int n, Array *digest, int dlen, Keyring_DigestState *state, DigestState* (*fn)(uchar*, ulong, uchar*, DigestState*))
{
	Heap *h;
	XDigestState *ds;
	uchar *cbuf, *cdigest;

	if(buf != H){
		n = digestcount(buf, n);
		cbuf = buf->data;
	}else{
		if(n != 0)
			error(exInval);
		cbuf = nil;
	}

	if(digest != H){
		if(digest->len < dlen)
			error(exBadDigest);
		cdigest = digest->data;
	} else
		cdigest = nil;

	if(state == H){
		h = heap(TDigestState);
		ds = H2D(XDigestState*, h);
		memset(&ds->state, 0, sizeof(ds->state));
	} else
		ds = checktype(state, TDigestState, "DigestState", 1);

	(*fn)(cbuf, n, cdigest, &ds->state);

	return (Keyring_DigestState*)ds;
}

void
Keyring_sha1(void *fp)
{
	F_Keyring_sha1 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, SHA1dlen, f->state, sha1);
}

void
Keyring_sha224(void *fp)
{
	F_Keyring_sha224 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, SHA224dlen, f->state, sha224);
}

void
Keyring_sha256(void *fp)
{
	F_Keyring_sha256 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, SHA256dlen, f->state, sha256);
}

void
Keyring_sha384(void *fp)
{
	F_Keyring_sha384 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, SHA384dlen, f->state, sha384);
}

void
Keyring_sha512(void *fp)
{
	F_Keyring_sha512 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, SHA512dlen, f->state, sha512);
}

/*
 * SHA-3 (FIPS 202) one-shot digest functions
 * These use SHA3state internally (not DigestState), so they
 * are one-shot only — no incremental hashing support.
 */
void
Keyring_sha3_256(void *fp)
{
	F_Keyring_sha3_256 *f;
	uchar *cbuf;
	int n;

	f = fp;
	*f->ret = 0;

	if(f->buf == H || f->digest == H)
		return;

	n = digestcount(f->buf, f->n);
	if(f->digest->len < SHA3_256dlen)
		error(exBadDigest);

	cbuf = f->buf->data;
	sha3_256(cbuf, n, f->digest->data);
	*f->ret = SHA3_256dlen;
}

void
Keyring_sha3_512(void *fp)
{
	F_Keyring_sha3_512 *f;
	uchar *cbuf;
	int n;

	f = fp;
	*f->ret = 0;

	if(f->buf == H || f->digest == H)
		return;

	n = digestcount(f->buf, f->n);
	if(f->digest->len < SHA3_512dlen)
		error(exBadDigest);

	cbuf = f->buf->data;
	sha3_512(cbuf, n, f->digest->data);
	*f->ret = SHA3_512dlen;
}

void
Keyring_md5(void *fp)
{
	F_Keyring_md5 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	*f->ret = keyring_digest_x(f->buf, f->n, f->digest, MD5dlen, f->state, md5);
}

static Keyring_DigestState*
keyring_hmac_x(Array *data, int n, Array *key, Array *digest, int dlen, Keyring_DigestState *state, DigestState* (*fn)(uchar*, ulong, uchar*, ulong, uchar*, DigestState*))
{
	Heap *h;
	XDigestState *ds;
	uchar *cdata, *cdigest;

	if(data != H){
		n = digestcount(data, n);
		cdata = data->data;
	}else{
		if(n != 0)
			error(exInval);
		cdata = nil;
	}

	if(key == H)
		error(exBadKey);

	if(digest != H){
		if(digest->len < dlen)
			error(exBadDigest);
		cdigest = digest->data;
	} else
		cdigest = nil;

	if(state == H){
		h = heap(TDigestState);
		ds = H2D(XDigestState*, h);
		memset(&ds->state, 0, sizeof(ds->state));
	} else
		ds = checktype(state, TDigestState, "DigestState", 1);

	(*fn)(cdata, n, key->data, key->len, cdigest, &ds->state);

	return (Keyring_DigestState*)ds;
}

void
Keyring_hmac_sha1(void *fp)
{
	F_Keyring_hmac_sha1 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = keyring_hmac_x(f->data, f->n, f->key, f->digest, SHA1dlen, f->state, hmac_sha1);
}

void
Keyring_hmac_md5(void *fp)
{
	F_Keyring_hmac_md5 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = keyring_hmac_x(f->data, f->n, f->key, f->digest, MD5dlen, f->state, hmac_md5);
}

void
Keyring_hmac_sha256(void *fp)
{
	F_Keyring_hmac_sha256 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = keyring_hmac_x(f->data, f->n, f->key, f->digest, SHA256dlen, f->state, hmac_sha256);
}

void
Keyring_hmac_sha384(void *fp)
{
	F_Keyring_hmac_sha384 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = keyring_hmac_x(f->data, f->n, f->key, f->digest, SHA384dlen, f->state, hmac_sha384);
}

void
Keyring_hmac_sha512(void *fp)
{
	F_Keyring_hmac_sha512 *f;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);
	*f->ret = keyring_hmac_x(f->data, f->n, f->key, f->digest, SHA512dlen, f->state, hmac_sha512);
}

void
Keyring_dhparams(void *fp)
{
	F_Keyring_dhparams *f;
	mpint *p, *alpha;
	Cres *c;
	void *v;
	int ok;

	f = fp;
	v = f->ret->t0;
	f->ret->t0 = H;
	destroy(v);
	v = f->ret->t1;
	f->ret->t1 = H;
	destroy(v);

	genbits(f->nbits, MinDHbits, Maxgenbits);
	p = mpnew(0);
	alpha = mpnew(0);
	ok = 0;
	release();
	if(f->nbits == 1024)
		DSAprimes(alpha, p, nil);
	else if(!getdhparams(f->nbits, p, alpha))
		ok = gensafeprime(p, alpha, f->nbits, 0);
	acquire();
	if(ok < 0){
		/*
		 * the search gave up: two zeros are no group.  It also stops
		 * when this Prog is being killed, and then there is nothing
		 * to raise: the kill is raised as the call returns, and an
		 * error raised here left the Prog broken in its place.
		 */
		mpfree(p);
		mpfree(alpha);
		if(!upkilled())
			error("dhparams: no prime found");
		return;
	}
	/* newIPint frees its number when it raises, but not the other one */
	c = cres(p, (void(*)(void*))mpfree);
	f->ret->t0 = newIPint(alpha);
	c->p = nil;
	destroy(c);
	f->ret->t1 = newIPint(p);
}

/*
 * Messages on a stream: a count in decimal and a newline, then that
 * many bytes.  The count is four digits, zero-padded, up to 9999, as it
 * always was; a longer message's is its five or six digits with no
 * leading zero.  (An end that knows only the four reads a digit where
 * it wants the newline and says "input or format error"; it could not
 * have been sent such a message before, when the sender wrote five
 * bytes of a six-byte header and then the data.)  One length has one
 * form.  An error is "!ddd" and a newline, then the text.
 */
static int
sendmsg(int fd, void *buf, int n)
{
	char num[16];
	int hn;

	if(n < 0 || n > Maxmsg){
		kwerrstr(Etoolong);
		return -1;
	}
	if(n <= Maxshorthdr)
		hn = snprint(num, sizeof(num), "%4.4d\n", n);
	else
		hn = snprint(num, sizeof(num), "%d\n", n);
	release();
	if(kwrite(fd, num, hn) != hn){
		acquire();
		return -1;
	}
	n = kwrite(fd, buf, n);
	acquire();
	return n;
}

void
Keyring_sendmsg(void *fp)
{
	F_Keyring_sendmsg *f;
	int n;

	f = fp;
	*f->ret = -1;
	if(f->fd == H || f->buf == H || f->n < 0)
		return;
	n = f->n;
	if(n < 0 || n > f->buf->len)
		error(exBounds);
	*f->ret = sendmsg(f->fd->fd, f->buf->data, n);
}

static int
senderr(int fd, char *err, int addrmt)
{
	char num[10];
	int n, m;

	n = strlen(err);
	m = 0;
	if(addrmt)
		m = strlen("remote: ");
	/* three digits of count: a longer text made a header of six bytes, of which five were sent */
	if(n+m > 999){
		kwerrstr(Etoolong);
		return -1;
	}
	release();
	snprint(num, sizeof(num), "!%3.3d\n", n+m);
	if(kwrite(fd, num, 5) != 5){
		acquire();
		return -1;
	}
	if(addrmt)
		kwrite(fd, "remote: ", m);
	n = kwrite(fd, err, n);
	acquire();
	return n;
}

void
Keyring_senderrmsg(void *fp)
{
	F_Keyring_senderrmsg *f;
	char *s;

	f = fp;
	*f->ret = -1;
	if(f->fd == H)
		return;
	s = string2c(f->s);
	if(senderr(f->fd->fd, s, 0) > 0)
		*f->ret = 0;
}

static int
nreadn(int fd, void *av, int n)
{

	char *a;
	long m, t;

	a = av;
	t = 0;
	while(t < n){
		m = kread(fd, a+t, n-t);
		if(m <= 0){
			if(t == 0)
				return m;
			break;
		}
		t += m;
	}
	return t;
}

#define MSG "input or format error"

static void
getmsgerr(char *buf, int n, int r)
{
	char *e;
	int l;

	/* Null check added for security (cppcheck warning) */
	if(buf == nil)
		return;
	e = r>0? MSG: "hungup";
	l = strlen(e)+1;
	if(n > l)
		n = l;
	memmove(buf, e, n-1);
	buf[n-1] = 0;
}

/*
 * A message's header: its length, with *iserr set for an error
 * message; or -1 with the reason in err.  Called with the VM let go.
 *
 * Authentication framing is exactly "dddd\n" for data up to 9999
 * bytes, "ddddd\n" or "dddddd\n" with no leading zero for more, and
 * "!ddd\n" for errors.  strtoul accepted signs, whitespace, and a
 * missing newline, allowing non-canonical pre-auth frames to reach the
 * expensive handshake state machine.
 */
static int
getmsghdr(int fd, int *iserr, char *err, int nerr)
{
	char num[8];
	int i, len, r, start;

	*iserr = 0;
	if((r = nreadn(fd, num, 5)) != 5){
		getmsgerr(err, nerr, r);
		return -1;
	}
	start = 0;
	if(num[0] == '!'){
		*iserr = 1;
		start = 1;
	}
	len = 0;
	for(i = start; i < 4; i++){
		if(num[i] < '0' || num[i] > '9'){
			getmsgerr(err, nerr, 1);
			return -1;
		}
		len = len*10 + num[i]-'0';
	}
	if(num[4] == '\n')
		return len;

	/* the long form: one or two digits more, the first not 0 */
	if(*iserr || num[0] == '0' || num[4] < '0' || num[4] > '9'){
		getmsgerr(err, nerr, 1);
		return -1;
	}
	len = len*10 + num[4]-'0';
	if((r = nreadn(fd, num, 1)) != 1){
		getmsgerr(err, nerr, r);
		return -1;
	}
	if(num[0] >= '0' && num[0] <= '9'){
		len = len*10 + num[0]-'0';
		if((r = nreadn(fd, num, 1)) != 1){
			getmsgerr(err, nerr, r);
			return -1;
		}
	}
	if(num[0] != '\n'){
		getmsgerr(err, nerr, 1);
		return -1;
	}
	/*
	 * The length is the sender's: nothing is allocated or read for
	 * one beyond what a message may be.
	 */
	if(len > Maxmsg){
		strecpy(err, err+nerr, Etoolong);
		return -1;
	}
	return len;
}

/*
 * The next message into buf (n bytes), with a zero byte after it: its
 * length, minus its length for an error message, or -1 with the reason
 * in buf.  A message that does not fit buf is an error, not a part.
 */
static int
getmsg(int fd, char *buf, int n)
{
	int len, r, iserr;

	release();
	len = getmsghdr(fd, &iserr, buf, n);
	if(len < 0){
		acquire();
		return -1;
	}
	if(len >= n){
		strecpy(buf, buf+n, Etoolong);
		acquire();
		return -1;
	}
	if((r = nreadn(fd, buf, len)) != len){
		getmsgerr(buf, n, r);
		acquire();
		return -1;
	}

	buf[len] = 0;
	acquire();
	if(iserr)
		return -len;

	return len;
}

/*
 * Keyfile framing (readauthinfo / writeauthinfo only).
 *
 * The on-disk signer keyfile carries whole keys: an ML-DSA-87 secret+public
 * message is ~13KB and larger CNSA keys (SLH-DSA) bigger still, exceeding the
 * fixed 4-digit ("dddd\n", <=9999) frame that getmsg/sendmsg use for the STS
 * wire handshake.  A keyfile is a trusted local file, not adversarial pre-auth
 * input, so it uses a variable-width decimal header "d+\n" bounded by Maxbuf.
 * The strict wire frame is left unchanged (see #315).  The variable reader
 * also still parses legacy 4-digit keyfiles, so old keyfiles keep working.
 */
static int
sendkfmsg(int fd, void *buf, int n)
{
	char num[16];
	int hn;

	release();
	hn = snprint(num, sizeof(num), "%d\n", n);
	if(kwrite(fd, num, hn) != hn){
		acquire();
		return -1;
	}
	n = kwrite(fd, buf, n);
	acquire();
	return n;
}

static int
getkfmsg(int fd, char *buf, int n)
{
	int i, len, r;
	char c;

	release();
	len = 0;
	for(i = 0;; i++){
		if((r = nreadn(fd, &c, 1)) != 1){
			getmsgerr(buf, n, r);
			acquire();
			return -1;
		}
		if(c == '\n')
			break;
		if(i >= 8 || c < '0' || c > '9'){	/* digits only, bounded */
			getmsgerr(buf, n, 1);
			acquire();
			return -1;
		}
		len = len*10 + (c - '0');
	}
	if(i == 0){				/* empty header */
		getmsgerr(buf, n, 1);
		acquire();
		return -1;
	}
	r = -1;
	if(len < 0 || len >= n || (r = nreadn(fd, buf, len)) != len){
		getmsgerr(buf, n, r);
		acquire();
		return -1;
	}
	buf[len] = 0;
	acquire();
	return len;
}

void
Keyring_getmsg(void *fp)
{
	F_Keyring_getmsg *f;
	char *buf, err[128];
	int n, r, fd, iserr;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);
	if(f->fd == H){
		kwerrstr("nil fd");
		return;
	}
	fd = f->fd->fd;

	/*
	 * The message's own length is allocated, once its header has
	 * said what that is and it is within Maxmsg (it was 4096 bytes
	 * for every message, and a longer one was "input or format
	 * error" with its bytes left in the stream).
	 */
	buf = nil;
	release();
	n = getmsghdr(fd, &iserr, err, sizeof(err));
	if(n >= 0){
		buf = malloc(n+1);
		if(buf == nil){
			strecpy(err, err+sizeof(err), exNomem);
			n = -1;
		}else if((r = nreadn(fd, buf, n)) != n){
			getmsgerr(err, sizeof(err), r);
			n = -1;
		}else
			buf[n] = 0;
	}
	acquire();
	if(n < 0){
		kwerrstr("%s", err);
		free(buf);
		return;
	}
	if(iserr){
		/* an error message: its text is the error */
		kwerrstr("%s", buf);
		free(buf);
		return;
	}

	*f->ret = mem2array(buf, n);
	free(buf);
}

/*
 * CNSA 2.0 strict mode — fleet-wide policy via the host CNSAMODE env var
 * (the emu also reflects it into Inferno /env/cnsamode for Limbo tools);
 * on bare metal, getenv answers from the kernel's switch, which boot
 * throws when the card has a cnsamode file (os/arm64/notyet.c).
 * When on, the native STS handshake uses ML-KEM-1024 (FIPS 203, NIST
 * Category 5) instead of ML-KEM-768. Every node in a CNSA-mode fleet must
 * agree; a mixed 768/1024 pair fails the public-key length check, by design
 * (no silent downgrade). Cached: the policy is fixed at node launch.
 */
static int
cnsamode(void)
{
	static int m = -1;
	char *e;

	if(m < 0){
		e = getenv("CNSAMODE");
		m = (e != nil && e[0] != 0 && e[0] != '0' && e[0] != 'n' && e[0] != 'N');
	}
	return m;
}

/*
 * The mode's rule for the keys of an authentication, as login(2)'s
 * cnsakey has it for the programs that make and issue them (CNSA 2.0):
 * ML-DSA-87 for every signature, SHA-384 or SHA-512 under one, and a
 * Diffie-Hellman modulus of 3072 bits or more.  The mode chose
 * ML-KEM-1024 below and took whatever key file it was given: a node in
 * it authenticated with an Ed25519 key over a 2048-bit group, and to a
 * peer that had one, and each signed the exchange over SHA-256.
 */
enum
{
	CNSAdhbits	= 3072,
};

static int
cnsasig(Keyring_SigAlg *sa)
{
	return sa != H && sa->name != H && strcmp(string2c(sa->name), "mldsa87") == 0;
}

static int
cnsahash(String *ha)
{
	char *s;

	if(ha == H)
		return 0;
	s = string2c(ha);
	return strcmp(s, "sha384") == 0 || strcmp(s, "sha512") == 0;
}

/*
 * The ML-KEM material of one authentication, in one heap block. It was
 * seven arrays on Keyring_auth's C stack, 9,440 bytes of them, which the
 * hosted emulator's 32KB thread stacks carried and the native kernel's
 * 16KB kernel stacks do not: every Limbo program on bare metal runs on
 * the Dis VM kproc's kernel stack, and this builtin overran it on the
 * first authenticated connection a Raspberry Pi 3 ever took -- a
 * scheduler panic, a corrupted heap, and a fault loop that needed the
 * power switch (#725). libsec's ML-KEM already keeps its polynomials on
 * the heap for the same reason (mlkem.c); this is the same rule one
 * level up. Wiped and freed at out:, on every path.
 */
typedef struct Kembuf Kembuf;
struct Kembuf
{
	uchar	myek[MLKEM1024_PKLEN];
	uchar	mydk[MLKEM1024_SKLEN];
	uchar	hisek[MLKEM1024_PKLEN];
	uchar	myct[MLKEM1024_CTLEN];
	uchar	hisct[MLKEM1024_CTLEN];
	uchar	ss_local[MLKEM_SSLEN];
	uchar	ss_remote[MLKEM_SSLEN];
};

void
Keyring_auth(void *fp)
{
	F_Keyring_auth *f;
	mpint *r0, *r1, *p, *alpha, *alphar0, *alphar1, *alphar0r1, *pm1;
	SK *mysk;
	PK *mypk, *spk, *hispk;
	Certificate *cert, *hiscert, *alphacert;
	char *buf, *err, *argerr;
	uchar *cvb;
	int n, fd;
	long now;
	Keyring_Authinfo *info;
	/* hybrid post-quantum key agreement material. Buffers are sized for the
	 * larger ML-KEM-1024 (CNSA 2.0 strict); pklen/ctlen select the in-use
	 * parameter set at runtime. They live on the heap, not the stack:
	 * see Kembuf. */
	Kembuf *kem;
	uchar *myek, *mydk, *hisek, *myct, *hisct, *ss_local, *ss_remote;
	uchar *kss_lo, *kss_hi, *ek_lo, *ek_hi;
	void **k;
	int cmp;
	int cnsa = cnsamode();
	int pklen = cnsa ? MLKEM1024_PKLEN : MLKEM768_PKLEN;
	int ctlen = cnsa ? MLKEM1024_CTLEN : MLKEM768_CTLEN;

	hispk = H;
	hiscert = H;
	alphacert = H;
	err = nil;

	/* null out the return values */
	f = fp;
	destroy(f->ret->t0);
	f->ret->t0 = H;
	destroy(f->ret->t1);
	f->ret->t1 = H;
	r0 = r1 = alphar0 = alphar1 = alphar0r1 = pm1 = nil;

	/* check args */
	if(f->fd == H || f->fd->fd < 0){
		retstr("bad fd", &f->ret->t0);
		return;
	}
	fd = f->fd->fd;

	/*
	 * The keys, looked at before anything is allocated: a key that
	 * is none raises, and that was after the 48K buffer and the
	 * ML-KEM block were made, which were then never freed (59K a
	 * call, from a program with an Authinfo of its own making). What
	 * is said to the peer about a missing one is still said after the
	 * versions are exchanged.
	 */
	info = f->info;
	argerr = nil;
	mysk = nil;
	mypk = spk = nil;
	cert = nil;
	p = alpha = nil;
	if(info == H)
		argerr = "no authentication information";
	else if(info->p == H)
		argerr = "missing diffie hellman mod";
	else if(info->alpha == H)
		argerr = "missing diffie hellman base";
	else{
		mysk = checkSK(info->mysk);
		mypk = checkPK(info->mypk);
		cert = checkCertificate(info->cert);
		spk = checkPK(info->spk);
		p = checkIPint(info->p);
		alpha = checkIPint(info->alpha);
		/*
		 * The modulus is the caller's. Zero is divided by (libmp
		 * raises, with everything here allocated). The two shares
		 * in base 64 and the two ML-KEM keys are signed from buf,
		 * and were copied there whatever their length: past its end
		 * with a modulus of a quarter of a million bits. The groups
		 * in use are of 2048 to 8192 bits.
		 */
		if(p->sign < 0)
			argerr = "-ve modulus";
		else if(p->top == 0 || mpsignif(p) > Maxdhbits)
			argerr = "bad diffie hellman mod";
		else if(cnsa){
			/* said to the peer as well, after the versions */
			if(!cnsasig(mysk->x.sa) || !cnsasig(mypk->x.sa))
				argerr = "CNSA mode: the key is not ML-DSA-87";
			else if(!cnsasig(spk->x.sa) || !cnsasig(cert->x.sa))
				argerr = "CNSA mode: the signer's key or the certificate is not ML-DSA-87";
			else if(!cnsahash(cert->x.ha))
				argerr = "CNSA mode: the certificate is not over SHA-384 or SHA-512";
			else if(mpsignif(p) < CNSAdhbits)
				argerr = "CNSA mode: the Diffie-Hellman modulus is under 3072 bits";
		}
	}

	/*
	 * The keys, the certificate and the two numbers are the
	 * Authinfo's fields, and the exchange lets the VM go at every
	 * message and every exponentiation: each is kept for the call
	 * (see keep), as a thread assigning a field meanwhile freed what
	 * the exchange was signing with or sending.
	 */
	k = keep(&f->info, 6);
	if(info != H && info->p != H && info->alpha != H){
		keepref(k, 1, mysk);
		keepref(k, 2, mypk);
		keepref(k, 3, cert);
		keepref(k, 4, spk);
		keepref(k, 5, info->p);
		keepref(k, 6, info->alpha);
	}

	buf = malloc(Maxbuf);
	if(buf == nil){
		unkeep(&f->info);
		retstr(exNomem, &f->ret->t0);
		return;
	}
	kem = malloc(sizeof(Kembuf));
	if(kem == nil){
		free(buf);
		unkeep(&f->info);
		retstr(exNomem, &f->ret->t0);
		return;
	}
	/* The peer must never receive allocator residue if a later ML-KEM
	 * allocation fails.  The return values below are checked as the primary
	 * fail-closed path; zeroing here is defence in depth. */
	memset(kem, 0, sizeof(Kembuf));
	myek = kem->myek;
	mydk = kem->mydk;
	hisek = kem->hisek;
	myct = kem->myct;
	hisct = kem->hisct;
	ss_local = kem->ss_local;
	ss_remote = kem->ss_remote;

	/* send auth protocol version number (2 = hybrid PQ; required) */
	if(sendmsg(fd, "2", 1) <= 0){
		err = MSG;
		goto out;
	}

	/* get auth protocol version number */
	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	buf[n] = 0;
	/*
	 * Require the version token to be exactly "2".  atoi() would accept
	 * non-canonical encodings such as "2abc", "0002", "+2" or " 2",
	 * widening the pre-auth attack surface; demand a single canonical byte.
	 */
	if(n != 1 || buf[0] != '2'){
		err = "incompatible authentication protocol (need hybrid PQ v2)";
		goto out;
	}

	if(argerr != nil){
		err = argerr;
		goto out;
	}

	r0 = mpnew(0);
	r1 = mpnew(0);
	alphar0 = mpnew(0);
	alphar0r1 = mpnew(0);

	/* generate alpha**r0 */
	release();
	mprand(mpsignif(p), genrandom, r0);
	mpexp(alpha, r0, p, alphar0);
	acquire();

	/* generate ephemeral ML-KEM keypair for hybrid PQ key agreement */
	release();
	if(cnsa)
		n = mlkem1024_keygen(myek, mydk);
	else
		n = mlkem768_keygen(myek, mydk);
	acquire();
	if(n != 0){
		err = "ml-kem key generation failed";
		goto out;
	}

	/* send alpha**r0 mod p, mycert, and mypk */
	n = bigtobase64(alphar0, buf, Maxbuf);
	if(sendmsg(fd, buf, n) <= 0){
		err = MSG;
		goto out;
	}

	n = certtostr(cert, buf, Maxbuf);
	if(sendmsg(fd, buf, n) <= 0){
		err = MSG;
		goto out;
	}

	n = pktostr(mypk, buf, Maxbuf);
	if(sendmsg(fd, buf, n) <= 0){
		err = MSG;
		goto out;
	}

	/* send my ML-KEM public key */
	if(sendmsg(fd, (char*)myek, pklen) <= 0){
		err = MSG;
		goto out;
	}

	/* get alpha**r1 mod p, hiscert, hispk */
	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	buf[n] = 0;
	alphar1 = strtomp(buf, nil, 64, nil);

	/*
	 * strtomp() returns nil when the peer sends a value with no valid
	 * base64/mpint digits (e.g. a non-base64 DH share).  mpcmp()
	 * dereferences its arguments unconditionally, so passing nil here is
	 * a pre-auth remote crash (INFR-322).  Reject it before any compare.
	 */
	if(alphar1 == nil){
		err = "malformed diffie hellman share";
		goto out;
	}

	/*
	 * Validate the peer's DH share before doing any further work:
	 * require 1 < alphar1 < p-1 (INFR-323).  Rejecting <= 1 also rejects
	 * zero and negative values because mpcmp() is sign-aware; rejecting
	 * >= p-1 also rejects >= p.  The weak shares 0, 1, p-1 (and p) force
	 * the shared secret into a tiny subgroup and must never be accepted.
	 */
	if(mpcmp(alphar1, mpone) <= 0){
		err = "implausible parameter value";
		goto out;
	}
	pm1 = mpnew(0);
	mpsub(p, mpone, pm1);
	if(mpcmp(alphar1, pm1) >= 0){
		err = "implausible parameter value";
		goto out;
	}

	/* if alpha**r1 == alpha**r0, someone may be trying a replay */
	if(mpcmp(alphar0, alphar1) == 0){
		err = "possible replay attack";
		goto out;
	}

	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	buf[n] = 0;
	hiscert = strtocert(buf);
	if(hiscert == H){
		err = "bad certificate syntax";
		goto out;
	}
	certimmutable(hiscert);		/* hide from the garbage collector */

	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	buf[n] = 0;
	hispk = strtopk(buf);
	if(hispk == H){
		err = "bad public key";
		goto out;
	}
	pkimmutable(hispk);		/* hide from the garbage collector */

	/* verify his public key */
	if(verify(spk, hiscert, buf, n) == 0){
		err = "pk doesn't match certificate";
		goto out;
	}

	/*
	 * the peer's key file is held to the mode's rule as ours is (its
	 * certificate is our signer's, but its own key is whatever the
	 * signer certified)
	 */
	if(cnsa && (!cnsasig(hispk->x.sa) || !cnsasig(hiscert->x.sa) || !cnsahash(hiscert->x.ha))){
		err = "CNSA mode: the peer's key or certificate is not ML-DSA-87 over SHA-384 or SHA-512";
		goto out;
	}

	/* check expiration date - in seconds of epoch */

	now = osusectime()/1000000;
	if(hiscert->x.exp != 0 && hiscert->x.exp <= now){
		err = "certificate expired";
		goto out;
	}

	/* get his ML-KEM public key (sent right after his pk) */
	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	if(n != pklen){
		/* say which side is in CNSA mode: the policy is per node, set
		 * by CNSAMODE where each was started, and a node started
		 * another way (a terminal's shell, not launchd) can differ */
		if(n == MLKEM1024_PKLEN)
			err = "bad ml-kem public key length: the peer is in CNSA mode (ML-KEM-1024), this node is not; set CNSAMODE alike";
		else if(n == MLKEM768_PKLEN)
			err = "bad ml-kem public key length: this node is in CNSA mode (ML-KEM-1024), the peer is not; set CNSAMODE alike";
		else
			err = "bad ml-kem public key length";
		goto out;
	}
	memmove(hisek, buf, pklen);

	/* encapsulate to his ek, send the ciphertext */
	release();
	if(cnsa)
		n = mlkem1024_encaps(myct, ss_local, hisek);
	else
		n = mlkem768_encaps(myct, ss_local, hisek);
	acquire();
	if(n != 0){
		err = "ml-kem encapsulation failed";
		goto out;
	}
	if(sendmsg(fd, (char*)myct, ctlen) <= 0){
		err = MSG;
		goto out;
	}

	/* get his ciphertext, decapsulate with my dk */
	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	if(n != ctlen){
		err = "bad ml-kem ciphertext length";
		goto out;
	}
	memmove(hisct, buf, ctlen);
	if(cnsa)
		n = mlkem1024_decaps(ss_remote, hisct, mydk);
	else
		n = mlkem768_decaps(ss_remote, hisct, mydk);
	if(n != 0){
		err = "ml-kem decapsulation failed";
		goto out;
	}

	/*
	 * sign alpha**r0, alpha**r1 and both ML-KEM public keys, then send.
	 * Binding the eks into the signed transcript authenticates the PQ
	 * key agreement: an active attacker cannot substitute ML-KEM keys
	 * without invalidating the signature.
	 */
	n = bigtobase64(alphar0, buf, Maxbuf);
	n += bigtobase64(alphar1, buf+n, Maxbuf-n);
	if(n > Maxbuf - 2*pklen){
		err = "bad diffie hellman mod";
		goto out;
	}
	memmove(buf+n, myek, pklen); n += pklen;
	memmove(buf+n, hisek, pklen); n += pklen;
	/* the exchange is signed over SHA-384 in CNSA mode, as the certificates are */
	alphacert = sign(mysk, cnsa? "sha384": "sha256", 0, (uchar*)buf, n);
	/*
	 * sign gives nil when it has no memory for its buffer or the
	 * algorithm made no signature: it went on to be printed, through
	 * nil
	 */
	if(alphacert == nil){
		alphacert = H;
		err = "cannot sign";
		goto out;
	}
	n = certtostr(alphacert, buf, Maxbuf);
	if(sendmsg(fd, buf, n) <= 0){
		err = MSG;
		goto out;
	}
	certmutable(alphacert);
	destroy(alphacert);
	alphacert = H;

	/* get signature of alpha**r1 and alpha**r0 and verify */
	n = getmsg(fd, buf, Maxbuf-1);
	if(n < 0){
		err = buf;
		goto out;
	}
	buf[n] = 0;
	alphacert = strtocert(buf);
	if(alphacert == H){
		err = "alpha**r1 doesn't match certificate";
		goto out;
	}
	certimmutable(alphacert);		/* hide from the garbage collector */
	if(cnsa && !cnsahash(alphacert->x.ha)){
		err = "CNSA mode: the peer signed the exchange over a hash that is not SHA-384 or SHA-512";
		goto out;
	}
	n = bigtobase64(alphar1, buf, Maxbuf);
	n += bigtobase64(alphar0, buf+n, Maxbuf-n);
	if(n > Maxbuf - 2*pklen){
		err = "bad diffie hellman mod";
		goto out;
	}
	memmove(buf+n, hisek, pklen); n += pklen;
	memmove(buf+n, myek, pklen); n += pklen;
	if(verify(hispk, alphacert, buf, n) == 0){
		err = "bad certificate";
		goto out;
	}

	/*
	 * We are now mutually authenticated.  Derive the session secret by
	 * combining the classical Diffie-Hellman secret alpha**(r0*r1) with
	 * both ML-KEM shared secrets using SHA3-512.  ss_local is keyed
	 * to his ek (we encapsulated to it); ss_remote is keyed to my ek (he
	 * encapsulated to it).  Both peers order the two KEM secrets and eks
	 * identically by comparing the two public keys, so they derive the
	 * same 64-byte secret.  The result stays secret unless BOTH the DH
	 * and the ML-KEM problem are broken (hybrid / harvest-now-safe).
	 * 64 bytes gives the ssl device a full key + IV for any cipher.
	 */
	f->ret->t0 = stringdup(hispk->x.owner);
	mpexp(alphar1, r0, p, alphar0r1);
	n = mptobe(alphar0r1, nil, Maxbuf, &cvb);
	if(n < 0){
		err = "bad conversion";
		goto out;
	}

	cmp = memcmp(myek, hisek, pklen);
	if(cmp == 0){
		memset(cvb, 0, n);
		free(cvb);
		err = "ml-kem public key collision";
		goto out;
	}
	if(cmp < 0){
		kss_lo = ss_remote; ek_lo = myek;	/* my ek is the smaller */
		kss_hi = ss_local;  ek_hi = hisek;
	}else{
		kss_lo = ss_local;  ek_lo = hisek;	/* his ek is the smaller */
		kss_hi = ss_remote; ek_hi = myek;
	}
	{
		uchar dig[SHA3_512dlen];
		int m;

		m = 0;
		memmove(buf+m, "infernode-pq-sts-v2", 19); m += 19;
		memmove(buf+m, cvb, n); m += n;
		memmove(buf+m, kss_lo, MLKEM_SSLEN); m += MLKEM_SSLEN;
		memmove(buf+m, kss_hi, MLKEM_SSLEN); m += MLKEM_SSLEN;
		memmove(buf+m, ek_lo, pklen); m += pklen;
		memmove(buf+m, ek_hi, pklen); m += pklen;
		sha3_512((uchar*)buf, m, dig);
		f->ret->t1 = mem2array(dig, SHA3_512dlen);
		memset(dig, 0, sizeof(dig));
	}
	memset(cvb, 0, n);
	free(cvb);

out:
	/* return status */
	if(f->ret->t0 == H){
		if(err == buf)
			senderr(fd, "missing your authentication data", 1);
		else
			senderr(fd, err, 1);
	}else
		sendmsg(fd, "OK", 2);

	/* read responses */
	if(err != buf){
		for(;;){
			n = getmsg(fd, buf, Maxbuf-1);
			if(n < 0){
				destroy(f->ret->t0);
				f->ret->t0 = H;
				destroy(f->ret->t1);
				f->ret->t1 = H;
				if(err == nil){
					if(n < -1)
						err = buf;
					else
						err = MSG;
				}
				break;
			}
			if(n == 2 && buf[0] == 'O' && buf[1] == 'K')
				break;
		}
	}

	/* set error and id to nobody */
	if(f->ret->t0 == H){
		if(err == nil)
			err = MSG;
		retstr(err, &f->ret->t0);
		if(f->setid)
			setid("nobody", 1);
	} else {
		/* change user id */
		if(f->setid)
			setid(string2c(f->ret->t0), 1);
	}
	
	/* free resources */
	if(hispk != H){
		pkmutable(hispk);
		destroy(hispk);
	}
	if(hiscert != H){
		certmutable(hiscert);
		destroy(hiscert);
	}
	if(alphacert != H){
		certmutable(alphacert);
		destroy(alphacert);
	}
	/* scrub the heap-backed ML-KEM secret key and shared secrets */
	secureZero(kem, sizeof(Kembuf));
	free(kem);
	/* scrub the combiner buffer: it held the DH secret and both ML-KEM shared secrets */
	memset(buf, 0, Maxbuf);
	free(buf);
	if(r0 != nil){
		/* scrub the ephemeral DH private exponents and the DH shared secret */
		memset(r0->p, 0, r0->size*sizeof(*r0->p));
		memset(r1->p, 0, r1->size*sizeof(*r1->p));
		memset(alphar0r1->p, 0, alphar0r1->size*sizeof(*alphar0r1->p));
		mpfree(r0);
		mpfree(r1);
		mpfree(alphar0);
		mpfree(alphar1);
		mpfree(alphar0r1);
	}
	mpfree(pm1);
	unkeep(&f->info);
}

static Keyring_Authinfo*
newAuthinfo(void)
{
	return H2D(Keyring_Authinfo*, heap(TAuthinfo));
}

void
Keyring_writeauthinfo(void *fp)
{
	F_Keyring_writeauthinfo *f;
	int n, fd;
	char *buf, *name;
	PK *spk;
	SK *mysk;
	Certificate *c;
	mpint *p, *alpha;
	Keyring_Authinfo *info;
	void **k;

	f = fp;
	*f->ret = -1;

	if(f->filename == H)
		error(exNilref);
	info = f->info;
	if(info == H)
		error(exNilref);
	alpha = checkIPint(info->alpha);
	p = checkIPint(info->p);
	spk = checkPK(info->spk);
	mysk = checkSK(info->mysk);
	c = checkCertificate(info->cert);
	/* the file's name, made while the VM is held: string2c may allocate */
	name = string2c(f->filename);

	/*
	 * what is written is the Authinfo's fields, and each write lets
	 * the VM go: kept for the call, as in auth
	 */
	k = keep(&f->info, 5);
	keepref(k, 1, info->alpha);
	keepref(k, 2, info->p);
	keepref(k, 3, spk);
	keepref(k, 4, mysk);
	keepref(k, 5, c);

	buf = malloc(Maxbuf);
	if(buf == nil){
		unkeep(&f->info);
		return;
	}

	/*
	 *  The file may already exist or be a file2chan file so first
	 *  try opening with truncation since create will change the
	 *  permissions of the file and create doesn't work with a
	 *  file2chan.
	 */
	release();
	fd = kopen(name, OTRUNC|OWRITE);
	if(fd < 0)
		fd = kcreate(name, OWRITE, 0600);
	if(fd < 0)
		fd = kopen(name, OWRITE);
	acquire();
	if(fd < 0)
		goto out;

	/* signer's public key */
	n = pktostr(spk, buf, Maxbuf);
	if(sendkfmsg(fd, buf, n) <= 0)
		goto out;

	/* certificate for my public key */
	n = certtostr(c, buf, Maxbuf);
	if(sendkfmsg(fd, buf, n) <= 0)
		goto out;

	/* my secret/public key */
	n = sktostr(mysk, buf, Maxbuf);
	if(sendkfmsg(fd, buf, n) <= 0)
		goto out;

	/* diffie hellman base */
	n = bigtobase64(alpha, buf, Maxbuf);
	if(sendkfmsg(fd, buf, n) <= 0)
		goto out;

	/* diffie hellman modulus */
	n = bigtobase64(p, buf, Maxbuf);
	if(sendkfmsg(fd, buf, n) <= 0)
		goto out;

	*f->ret = 0;
out:
	free(buf);
	if(fd >= 0){
		release();
		kclose(fd);
		acquire();
	}
	unkeep(&f->info);
}

void
Keyring_readauthinfo(void *fp)
{
	F_Keyring_readauthinfo *f;
	int fd;
	char *buf;
	int n, ok;
	PK *mypk;
	SK *mysk;
	SigAlg *sa;
	Keyring_Authinfo *ai;
	mpint *b;
	char *name;
	void *r, **k;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	ok = 0;

	if(f->filename == H)
		return;

	/*
	 * the Authinfo is the call's until it is whole (see keep): it
	 * was stored where the result goes and filled in field by field,
	 * the VM let go for each read
	 */
	name = string2c(f->filename);
	ai = newAuthinfo();
	k = keep(&f->filename, 1);
	k[1] = ai;

	buf = malloc(Maxbuf);
	if(buf == nil){
		unkeep(&f->filename);
		return;
	}

	release();
	fd = kopen(name, OREAD);
	acquire();
	if(fd < 0)
		goto out;

	/* signer's public key */
	n = getkfmsg(fd, buf, Maxbuf);
	if(n < 0)
		goto out;

	ai->spk = (Keyring_PK*)strtopk(buf);
	if(ai->spk == H)
		goto out;

	/* certificate for my public key */
	n = getkfmsg(fd, buf, Maxbuf);
	if(n < 0)
		goto out;
	ai->cert = (Keyring_Certificate*)strtocert(buf);
	if(ai->cert == H)
		goto out;

	/* my secret/public key */
	n = getkfmsg(fd, buf, Maxbuf);
	if(n < 0)
		goto out;
	mysk = strtosk(buf);
	ai->mysk = (Keyring_SK*)mysk;
	if(mysk == H)
		goto out;
	sa = checkSigAlg(mysk->x.sa);
	mypk = newPK(sa, stringdup(mysk->x.owner), 1);
	mypk->key = (*sa->vec->sk2pk)(mysk->key);
	ai->mypk = (Keyring_PK*)mypk;

	/* diffie hellman base */
	n = getkfmsg(fd, buf, Maxbuf);
	if(n < 0)
		goto out;
	/*
	 * a number that is none: newIPint raises on nil, and the buffer
	 * and the open file were then never given back (a key file with
	 * one bad character cost a descriptor each time it was read)
	 */
	b = strtomp(buf, nil, 64, nil);
	if(b == nil)
		goto out;
	ai->alpha = newIPint(b);

	/* diffie hellman modulus */
	n = getkfmsg(fd, buf, Maxbuf);
	if(n < 0)
		goto out;
	b = strtomp(buf, nil, 64, nil);
	if(b == nil)
		goto out;
	ai->p = newIPint(b);
	ok = 1;
out:
	free(buf);
	if(fd >= 0){
		release();
		kclose(fd);
		acquire();
		if(!ok)
			kwerrstr("%q: %s", name, MSG);
	}
	if(ok)
		k[1] = H;
	unkeep(&f->filename);
	if(ok)
		*f->ret = kept(ai);
}

/*
 * A cipher's state holds its key (AES's schedule, in three forms;
 * ChaCha's key itself; RC4's permutation) and a digest's may hold a
 * keyed hash's (HMAC).  None holds a pointer.  They were given back to
 * the heap as they were, and the key stayed in the freed block until
 * something else was put there: in the emulator's memory, a core file,
 * the heap as /prog/n/heap gives it to a debugger.  Cleared when the
 * block goes, by its last reference or by the collector.
 */
static void
freestate(Heap *h, int swept)
{
	USED(swept);
	secureZero(H2D(void*, h), h->t->size);
}

void
keyringmodinit(void)
{
	SigAlgVec *sav;
	extern SigAlgVec* elgamalinit(void);
	extern SigAlgVec* rsainit(void);
	extern SigAlgVec* dsainit(void);
	extern SigAlgVec* ed25519init(void);
	extern SigAlgVec* mldsa65init(void);
	extern SigAlgVec* mldsa87init(void);
	extern SigAlgVec* slhdsa192sinit(void);
	extern SigAlgVec* slhdsa256sinit(void);

	ipintsmodinit();	/* in case only Keyring is configured */
	TSigAlg = dtype(freeSigAlg, sizeof(SigAlg), SigAlgmap, sizeof(SigAlgmap));
	TSK = dtype(freeSK, sizeof(SK), SKmap, sizeof(SKmap));
	TPK = dtype(freePK, sizeof(PK), PKmap, sizeof(PKmap));
	TCertificate = dtype(freeCertificate, sizeof(Certificate), Certificatemap,
		sizeof(Certificatemap));
	TDigestState = dtype(freestate, sizeof(XDigestState), DigestStatemap,
		sizeof(DigestStatemap));
	TAESstate = dtype(freestate, sizeof(XAESstate), AESstatemap,
		sizeof(AESstatemap));
	TAESGCMstate = dtype(freestate, sizeof(XAESGCMstate), AESGCMstatemap,
		sizeof(AESGCMstatemap));
	TChaChastate = dtype(freestate, sizeof(XChaChastate), ChaChastatemap,
		sizeof(ChaChastatemap));
	TECpoint = dtype(freeheap, sizeof(XECpoint), ECpointmap,
		sizeof(ECpointmap));
	TRC4state = dtype(freestate, sizeof(XRC4state), RC4statemap,
		sizeof(RC4statemap));
	TAuthinfo = dtype(freeheap, sizeof(Keyring_Authinfo), Authinfomap, sizeof(Authinfomap));
	TDSAsk = dtype(freeheap, sizeof(Keyring_DSAsk), DSAskmap, sizeof(DSAskmap));
	TDSApk = dtype(freeheap, sizeof(Keyring_DSApk), DSApkmap, sizeof(DSApkmap));
	TDSAsig = dtype(freeheap, sizeof(Keyring_DSAsig), DSAsigmap, sizeof(DSAsigmap));
	TEGsk = dtype(freeheap, sizeof(Keyring_EGsk), EGskmap, sizeof(EGskmap));
	TEGpk = dtype(freeheap, sizeof(Keyring_EGpk), EGpkmap, sizeof(EGpkmap));
	TEGsig = dtype(freeheap, sizeof(Keyring_EGsig), EGsigmap, sizeof(EGsigmap));
	TRSAsk = dtype(freeheap, sizeof(Keyring_RSAsk), RSAskmap, sizeof(RSAskmap));
	TRSApk = dtype(freeheap, sizeof(Keyring_RSApk), RSApkmap, sizeof(RSApkmap));
	TRSAsig = dtype(freeheap, sizeof(Keyring_RSAsig), RSAsigmap, sizeof(RSAsigmap));

	/* Register signature algorithms - Ed25519 first as preferred modern algorithm */
	if((sav = ed25519init()) != nil)
		algs[nalg++] = sav;
	if((sav = elgamalinit()) != nil)
		algs[nalg++] = sav;
	if((sav = rsainit()) != nil)
		algs[nalg++] = sav;
	if((sav = dsainit()) != nil)
		algs[nalg++] = sav;
	if((sav = mldsa65init()) != nil)
		algs[nalg++] = sav;
	if((sav = mldsa87init()) != nil)
		algs[nalg++] = sav;
	if((sav = slhdsa192sinit()) != nil)
		algs[nalg++] = sav;
	if((sav = slhdsa256sinit()) != nil)
		algs[nalg++] = sav;

	TCres = dtype(freeCres, sizeof(Cres), nil, 0);

	fmtinstall('U', big64conv);
	builtinmod("$Keyring", Keyringmodtab, Keyringmodlen);
}

/*
 *  IO on a delimited channel (one that keeps a write's bounds: ssl(3)
 *  for up to a record, a pipe).  A message starting with 0x00 is a
 *  normal message.  One starting with 0xff is an error string.  Either
 *  is one write of at most Shortbuf bytes, and one read.
 *
 *  A longer message, up to Maxmsg bytes, starts with 0x01 and its
 *  length as four bytes, most significant first, and is read until
 *  that many bytes have come, in however many reads: ssl(3) sends a
 *  write past its record's 32K as several records.  (There was no such
 *  form: what was longer than 4095 bytes was cut to that by the sender
 *  with nothing said, so a certificate of ML-DSA-87, 6197 bytes of
 *  text, arrived as its first two thirds.  An end that does not know
 *  the long form takes its first byte for neither data nor an error,
 *  and says "failure".)
 *
 *  getbuf returns the message in *bufp, to be freed, and its length;
 *  or -1 with the reason in err, which for an error message is its
 *  text.
 */
static int
getbuf(int fd, uchar **bufp, char *err, int nerr)
{
	uchar *buf, *big;
	int len, m;
	ulong need;

	*bufp = nil;
	buf = malloc(Shortbuf);
	if(buf == nil){
		strecpy(err, err+nerr, exNomem);
		return -1;
	}
	release();
	len = kread(fd, buf, Shortbuf);
	if(len <= 0){
		acquire();
		free(buf);
		strecpy(err, err+nerr, "hungup");
		return -1;
	}
	if(buf[0] == 0){
		acquire();
		memmove(buf, buf+1, len-1);
		*bufp = buf;
		return len-1;
	}
	if(buf[0] == 1){
		/* the header may come alone or with the first of the data */
		while(len < Longhdr){
			m = kread(fd, buf+len, Longhdr-len);
			if(m <= 0)
				break;
			len += m;
		}
		need = 0;
		if(len >= Longhdr)
			need = (ulong)buf[1]<<24 | buf[2]<<16 | buf[3]<<8 | buf[4];
		/*
		 * the length is the sender's: within what a message may be,
		 * and more than fits the short form, which is the only way
		 * to send what does
		 */
		if(len < Longhdr || need < Shortbuf || need > Maxmsg || len-Longhdr > need){
			acquire();
			free(buf);
			strecpy(err, err+nerr, len < Longhdr? "hungup": need > Maxmsg? Etoolong: "failure");
			return -1;
		}
		big = malloc(need+1);
		if(big == nil){
			acquire();
			free(buf);
			strecpy(err, err+nerr, exNomem);
			return -1;
		}
		len -= Longhdr;
		memmove(big, buf+Longhdr, len);
		free(buf);
		while(len < need){
			m = kread(fd, big+len, need-len);
			if(m <= 0)
				break;
			len += m;
		}
		acquire();
		if(len < need){
			free(big);
			strecpy(err, err+nerr, "hungup");
			return -1;
		}
		*bufp = big;
		return len;
	}
	acquire();
	if(buf[0] != 0xff){
		/*
		 * this happens when the client's password is wrong: both sides use a digest of the
		 * password as a crypt key for devssl. When they don't match decryption garbles
		 * messages
		 */
		free(buf);
		strecpy(err, err+nerr, "failure");
		return -1;
	}

	/* error string, whole (it was cut to 63 bytes) */
	len--;
	if(len < 1)
		strecpy(err, err+nerr, "unknown");
	else {
		if(len >= nerr)
			len = nerr-1;
		memmove(err, buf+1, len);
		err[len] = 0;
	}
	free(buf);
	return -1;
}

void
Keyring_getstring(void *fp)
{
	F_Keyring_getstring *f;
	uchar *buf;
	char *err;
	int n;

	f = fp;
	destroy(f->ret->t0);
	f->ret->t0 = H;
	destroy(f->ret->t1);
	f->ret->t1 = H;

	if(f->fd == H)
		return;

	err = malloc(Shortbuf);
	if(err == nil)
		return;
	n = getbuf(f->fd->fd, &buf, err, Shortbuf);
	if(n < 0)
		retnstr(err, strlen(err), &f->ret->t1);
	else
		retnstr((char*)buf, n, &f->ret->t0);

	free(buf);
	free(err);
}

void
Keyring_getbytearray(void *fp)
{
	F_Keyring_getbytearray *f;
	uchar *buf;
	char *err;
	int n;

	f = fp;
	destroy(f->ret->t0);
	f->ret->t0 = H;
	destroy(f->ret->t1);
	f->ret->t1 = H;

	if(f->fd == H)
		return;

	err = malloc(Shortbuf);
	if(err == nil)
		return;
	n = getbuf(f->fd->fd, &buf, err, Shortbuf);
	if(n < 0)
		retnstr(err, strlen(err), &f->ret->t1);
	else
		f->ret->t0 = mem2array(buf, n);

	free(buf);
	free(err);
}

/*
 * n bytes of data, or -n of an error's text: the number of bytes
 * written, or -1 (a message longer than one may be is not sent).
 */
static int
putbuf(int fd, void *p, int n)
{
	uchar *buf;
	int iserr, hn;

	iserr = 0;
	if(n < 0){
		iserr = 1;
		n = -n;
	}
	if(n > Maxmsg || (iserr && n >= Shortbuf)){
		kwerrstr(Etoolong);
		return -1;
	}
	buf = malloc(n+Longhdr);
	if(buf == nil)
		return -1;

	if(n < Shortbuf){
		buf[0] = iserr? 0xff: 0;
		hn = 1;
	}else{
		buf[0] = 1;
		buf[1] = n>>24;
		buf[2] = n>>16;
		buf[3] = n>>8;
		buf[4] = n;
		hn = Longhdr;
	}
	/* copied before the VM is let go: p may be a string's own bytes */
	memmove(buf+hn, p, n);
	release();
	n = kwrite(fd, buf, n+hn);
	acquire();

	free(buf);
	return n;
}

void
Keyring_putstring(void *fp)
{
	F_Keyring_putstring *f;

	f = fp;
	*f->ret = -1;
	if(f->fd == H || f->s == H)
		return;
	*f->ret = putbuf(f->fd->fd, string2c(f->s), strlen(string2c(f->s)));
}

void
Keyring_puterror(void *fp)
{
	F_Keyring_puterror *f;

	f = fp;
	*f->ret = -1;
	if(f->fd == H || f->s == H)
		return;
	*f->ret = putbuf(f->fd->fd, string2c(f->s), -strlen(string2c(f->s)));
}

void
Keyring_putbytearray(void *fp)
{
	F_Keyring_putbytearray *f;
	int n;

	f = fp;
	*f->ret = -1;
	if(f->fd == H || f->a == H)
		return;
	n = f->n;
	if(n < 0 || n > f->a->len)
		error(exBounds);
	*f->ret = putbuf(f->fd->fd, f->a->data, n);
}

void
Keyring_aessetup(void *fp)
{
	F_Keyring_aessetup *f;
	Heap *h;
	XAESstate *is;
	uchar *ivec;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->key == H ||
	   f->key->len != 16 && f->key->len != 24 && f->key->len != 32)
		error(exBadKey);
	if(f->ivec != H){
		if(f->ivec->len < AESbsize)
			error(exBadIvec);
		ivec = f->ivec->data;
	}else
		ivec = nil;

	h = heap(TAESstate);
	is = H2D(XAESstate*, h);

	setupAESstate(&is->state, f->key->data, f->key->len, ivec);

	*f->ret = (Keyring_AESstate*)is;
}

void
Keyring_aescbc(void *fp)
{
	F_Keyring_aescbc *f;
	XAESstate *is;
	uchar *p;

	f = fp;

	if(f->buf == H)
		return;
	if(f->n < 0 || f->n > f->buf->len)
		error(exBounds);

	is = checktype(f->state, TAESstate, exBadState, 0);
	p = f->buf->data;

	if(f->direction == 0)
		aesCBCencrypt(p, f->n, &is->state);
	else
		aesCBCdecrypt(p, f->n, &is->state);
}

void
Keyring_aesgcmsetup(void *fp)
{
	F_Keyring_aesgcmsetup *f;
	Heap *h;
	XAESGCMstate *is;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	/*
	 * a key is 16, 24 or 32 bytes, as aessetup asks: any length was
	 * taken, and one that is no key's made a state that enciphered
	 * with no rounds (see libsec/aes.c)
	 */
	if(f->key == H || f->key->len != 16 && f->key->len != 24 && f->key->len != 32)
		error(exBadKey);
	if(f->iv == H || f->iv->len <= 0)
		error(exBadIvec);

	h = heap(TAESGCMstate);
	is = H2D(XAESGCMstate*, h);

	setupAESGCMstate(&is->state, f->key->data, f->key->len, f->iv->data, f->iv->len);

	*f->ret = (Keyring_AESGCMstate*)is;
}

void
Keyring_aesgcmencrypt(void *fp)
{
	F_Keyring_aesgcmencrypt *f;
	XAESGCMstate *is;
	uchar tag[16];
	uchar *buf;
	int ndat;

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(f->dat == H)
		return;

	is = checktype(f->state, TAESGCMstate, exBadState, 0);

	ndat = f->dat->len;

	/* copy plaintext to temp buffer, encrypt in place */
	buf = malloc(ndat);
	if(buf == nil)
		error(exNomem);
	memmove(buf, f->dat->data, ndat);

	if(aesgcm_encrypt(buf, ndat,
		f->aad != H ? f->aad->data : nil,
		f->aad != H ? f->aad->len : 0,
		tag, &is->state) < 0){
		free(buf);
		error(exBadState);
	}

	f->ret->t0 = mem2array(buf, ndat);
	f->ret->t1 = mem2array(tag, 16);
	free(buf);
}

void
Keyring_aesgcmdecrypt(void *fp)
{
	F_Keyring_aesgcmdecrypt *f;
	XAESGCMstate *is;
	uchar *buf;
	int ndat;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->dat == H)
		return;
	if(f->tag == H || f->tag->len != 16)
		error(exBadDigest);

	is = checktype(f->state, TAESGCMstate, exBadState, 0);

	ndat = f->dat->len;

	/* copy ciphertext to temp buffer, decrypt in place */
	buf = malloc(ndat);
	if(buf == nil)
		error(exNomem);
	memmove(buf, f->dat->data, ndat);

	if(aesgcm_decrypt(buf, ndat,
		f->aad != H ? f->aad->data : nil,
		f->aad != H ? f->aad->len : 0,
		f->tag->data, &is->state) != 0){
		/* authentication failed - return nil */
		free(buf);
		return;
	}

	*f->ret = mem2array(buf, ndat);
	free(buf);
}

void
Keyring_rc4setup(void *fp)
{
	F_Keyring_rc4setup *f;
	Heap *h;
	XRC4state *is;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->seed == H)
		return;
	/* a key of no bytes: the byte after the array was read and used as one */
	if(f->seed->len <= 0)
		error(exBadKey);

	h = heap(TRC4state);
	is = H2D(XRC4state*, h);

	setupRC4state(&is->state, f->seed->data, f->seed->len);

	*f->ret = (Keyring_RC4state*)is;
}

void
Keyring_rc4(void *fp)
{
	F_Keyring_rc4 *f;
	XRC4state *is;
	uchar *p;

	f = fp;
	if(f->buf == H)
		return;
	if(f->n < 0 || f->n > f->buf->len)
		error(exBounds);
	is = checktype(f->state, TRC4state, exBadState, 0);
	p = f->buf->data;
	rc4(&is->state, p, f->n);
}

/*
 * rc4skip and rc4back step the state as many times as a program says,
 * and did it holding the VM: the largest int stopped every Limbo thread
 * for six seconds. A long way is gone on a copy of the state, with the
 * VM let go.
 */
enum
{
	RC4relsteps	= 1<<20,
};

static void
rc4step(XRC4state *is, int n, void (*step)(RC4state*, int))
{
	RC4state st;

	if(n <= RC4relsteps){
		(*step)(&is->state, n);
		return;
	}
	st = is->state;
	release();
	(*step)(&st, n);
	acquire();
	is->state = st;
	memset(&st, 0, sizeof(st));
}

void
Keyring_rc4skip(void *fp)
{
	F_Keyring_rc4skip *f;
	XRC4state *is;

	f = fp;
	is = checktype(f->state, TRC4state, exBadState, 0);
	rc4step(is, f->n, rc4skip);
}

void
Keyring_rc4back(void *fp)
{
	F_Keyring_rc4back *f;
	XRC4state *is;

	f = fp;
	is = checktype(f->state, TRC4state, exBadState, 0);
	rc4step(is, f->n, rc4back);
}

/*
 *  public/secret keys, signing and verifying
 */

/*
 * The keys below are adts a program fills in, and libsec is given their
 * numbers as they are. What it would raise for (a modulus of zero to
 * divide by, a negative exponent) is refused here instead: libsec's own
 * raise comes after it has allocated its working numbers, which were
 * lost each time, a few kilobytes of the kernel's pool a call.
 */
static void
modulusok(mpint *m)
{
	if(m->top == 0 || m->sign < 0)
		error(exBadKey);
}

static void
exponentok(mpint *e)
{
	if(e->sign < 0)
		error(exBadKey);
}

/*
 * And their length: a key's numbers and what it is used on are IPints,
 * which may be megabytes, and libsec's time grows as the cube of a
 * modulus's length with nothing to end it sooner (see libinterp/ipint.c).
 * None is longer than a key the generators here make.
 */
static mpint*
keynum(void *ip)
{
	mpint *b;

	b = checkIPint(ip);
	if(mpsignif(b) > Maxgenbits)
		error(exBadKey);
	return b;
}

/*
 * A key adt's number for libsec: the number, with its cell kept in
 * k[i] until the call is over.  The builtins below let the VM go while
 * libsec works on the numbers, and they are fields: assigned by
 * another thread meanwhile, the number that was there was freed under
 * the computation.  See keep.
 */
static mpint*
keptnum(void **k, int i, void *ip)
{
	mpint *b;

	b = keynum(ip);
	keepref(k, i, ip);
	return b;
}

/* the numbers of a DSA public key, kept in k[i..i+3] */
static void
dsapk2pub(DSApub* p, Keyring_DSApk* pk, void **k, int i)
{
	if(pk == H)
		error(exNilref);
	p->p = keptnum(k, i, pk->p);
	p->q = keptnum(k, i+1, pk->q);
	p->alpha = keptnum(k, i+2, pk->alpha);
	p->key = keptnum(k, i+3, pk->key);
	modulusok(p->p);
	modulusok(p->q);
}

/*
 * A key to sign with or to make another like: its numbers are a
 * program's (the adt is filled in Limbo). dsasign looks for a k from 1
 * to q-1 and dsagen for a generator mod p, and with q of 1 or less, or
 * p of 2 or less, there is none: they looked for ever, released.
 */
static void
dsagenok(DSApub *p)
{
	mpint *t;
	int ok;

	if(mpcmp(p->q, mpone) <= 0 || mpcmp(p->p, mptwo) <= 0)
		error(exBadKey);
	/*
	 * q divides p-1, or they are no DSA key's (dsagen raised for it
	 * with everything made).  That they are prime is dsagen's to ask,
	 * with the VM let go: libsec/dsagen.c.
	 */
	t = mpnew(0);
	mpsub(p->p, mpone, t);
	mpmod(t, p->q, t);
	ok = t->top == 0;
	mpfree(t);
	if(!ok)
		error(exBadKey);
}

/* a DSA secret key's numbers, kept in k[1..5] */
static void
dsask2priv(DSApriv* p, Keyring_DSAsk* sk, void **k)
{
	if(sk == H || sk->pk == H)
		error(exNilref);
	dsapk2pub(&p->pub, sk->pk, k, 1);
	dsagenok(&p->pub);
	p->secret = keptnum(k, 5, sk->secret);
}

static void
dsapriv2sk(Keyring_DSAsk* sk, DSApriv* p)
{
	Keyring_DSApk* pk;

	pk = sk->pk;
	pk->p = ipcopymp(p->pub.p);
	pk->q = ipcopymp(p->pub.q);
	pk->alpha = ipcopymp(p->pub.alpha);
	pk->key = ipcopymp(p->pub.key);
	sk->secret = ipcopymp(p->secret);
}

/*
 * In each builtin below the result is made once libsec has answered,
 * of new cells, and then stored: the cell used to be stored where the
 * result goes before the VM was let go, and written to after.
 */
void
DSAsk_gen(void *fp)
{
	F_DSAsk_gen *f;
	Keyring_DSAsk *sk;
	Keyring_DSApk *opk;
	DSApriv *p;
	DSApub pub, *oldpk;
	Cres *c;
	void *v, **k;

	f = fp;
	oldpk = nil;
	opk = f->oldpk;
	k = keep(&f->oldpk, 4);
	if(opk != H){
		dsapk2pub(&pub, opk, k, 1);
		dsagenok(&pub);
		oldpk = &pub;
	}
	release();
	p = dsagen(oldpk);
	acquire();
	unkeep(&f->oldpk);
	c = cres(p, (void(*)(void*))dsaprivfree);
	sk = newthing(TDSAsk, 0);
	sk->pk = newthing(TDSApk, 0);
	dsapriv2sk(sk, p);
	destroy(c);
	v = *f->ret;
	*f->ret = sk;
	destroy(v);
}

void
DSAsk_sign(void *fp)
{
	F_DSAsk_sign *f;
	Keyring_DSAsig *sig;
	Keyring_DSAsk *sk;
	DSApriv p;
	mpint *m;
	DSAsig *s;
	Cres *c;
	void *v, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = f->k;
	k = keep(&f->k, 5);
	dsask2priv(&p, sk, k);
	m = keynum(f->m);
	release();
	s = dsasign(&p, m);
	acquire();
	unkeep(&f->k);
	if(s == nil)	/* a group that is none: dsasign makes no signature */
		error(exBadKey);
	c = cres(s, (void(*)(void*))dsasigfree);
	sig = newthing(TDSAsig, 0);
	sig->r = ipcopymp(s->r);
	sig->s = ipcopymp(s->s);
	destroy(c);
	*f->ret = sig;
}

void
DSApk_verify(void *fp)
{
	F_DSApk_verify *f;
	Keyring_DSApk *pk;
	DSApub p;
	DSAsig sig;
	mpint *m;
	void **k;
	int ok;

	f = fp;
	*f->ret = 0;
	if(f->m == H || f->sig == H)
		return;
	pk = f->k;
	k = keep(&f->k, 6);
	dsapk2pub(&p, pk, k, 1);
	sig.r = keptnum(k, 5, f->sig->r);
	sig.s = keptnum(k, 6, f->sig->s);
	m = keynum(f->m);
	release();
	ok = dsaverify(&p, &sig, m) == 0;
	acquire();
	unkeep(&f->k);
	*f->ret = ok;
}

/* the numbers of an ElGamal public key, kept in k[i..i+2] */
static void
egpk2pub(EGpub* p, Keyring_EGpk* pk, void **k, int i)
{
	if(pk == H)
		error(exNilref);
	p->p = keptnum(k, i, pk->p);
	p->alpha = keptnum(k, i+1, pk->alpha);
	p->key = keptnum(k, i+2, pk->key);
	modulusok(p->p);
}

/* an ElGamal secret key's numbers, kept in k[1..4] */
static void
egsk2priv(EGpriv* p, Keyring_EGsk* sk, void **k)
{
	if(sk == H || sk->pk == H)
		error(exNilref);
	egpk2pub(&p->pub, sk->pk, k, 1);
	/* egsign looks for a k from 1 to p-2: see dsagenok */
	if(mpcmp(p->pub.p, mptwo) <= 0)
		error(exBadKey);
	p->secret = keptnum(k, 4, sk->secret);
}

static void
egpriv2sk(Keyring_EGsk* sk, EGpriv* p)
{
	Keyring_EGpk* pk;

	pk = sk->pk;
	pk->p = ipcopymp(p->pub.p);
	pk->alpha = ipcopymp(p->pub.alpha);
	pk->key = ipcopymp(p->pub.key);
	sk->secret = ipcopymp(p->secret);
}

void
EGsk_gen(void *fp)
{
	F_EGsk_gen *f;
	Keyring_EGsk *sk;
	EGpriv *p;
	Cres *c;
	void *v;

	f = fp;
	genbits(f->nlen, MinDHbits, Maxgenbits);
	release();
	for(;;){
		p = eggen(f->nlen, f->nrep);
		if(p == nil || mpsignif(p->pub.p) == f->nlen)
			break;
		egprivfree(p);
	}
	acquire();
	if(p == nil){
		/* eggen found no group, or was told to stop: see dhparams */
		if(!upkilled())
			error("EGsk.gen: no key made");
		return;
	}
	c = cres(p, (void(*)(void*))egprivfree);
	sk = newthing(TEGsk, 0);
	sk->pk = newthing(TEGpk, 0);
	egpriv2sk(sk, p);
	destroy(c);
	v = *f->ret;
	*f->ret = sk;
	destroy(v);
}

void
EGsk_sign(void *fp)
{
	F_EGsk_sign *f;
	Keyring_EGsig *sig;
	Keyring_EGsk *sk;
	EGpriv p;
	mpint *m;
	EGsig *s;
	Cres *c;
	void *v, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = f->k;
	k = keep(&f->k, 4);
	egsk2priv(&p, sk, k);
	m = keynum(f->m);
	/*
	 * a key signatures can be made for without its secret is no key
	 * to sign with (libsec/egverify.c, which refuses to verify with
	 * one); looked at with the VM let go, as it is two exponentiations
	 */
	release();
	s = nil;
	if(egpubvalid(&p.pub) == 0)
		s = egsign(&p, m);
	acquire();
	unkeep(&f->k);
	if(s == nil)
		error(exBadKey);
	c = cres(s, (void(*)(void*))egsigfree);
	sig = newthing(TEGsig, 0);
	sig->r = ipcopymp(s->r);
	sig->s = ipcopymp(s->s);
	destroy(c);
	*f->ret = sig;
}

void
EGpk_verify(void *fp)
{
	F_EGpk_verify *f;
	Keyring_EGpk *pk;
	EGpub p;
	EGsig sig;
	mpint *m;
	void **k;
	int ok;

	f = fp;
	*f->ret = 0;
	if(f->m == H || f->sig == H)
		return;
	pk = f->k;
	k = keep(&f->k, 5);
	egpk2pub(&p, pk, k, 1);
	sig.r = keptnum(k, 4, f->sig->r);
	sig.s = keptnum(k, 5, f->sig->s);
	m = keynum(f->m);
	if(sig.s->sign < 0 || m->sign < 0){
		unkeep(&f->k);
		return;	/* exponents, to egverify: no signature */
	}
	release();
	ok = egverify(&p, &sig, m) == 0;
	acquire();
	unkeep(&f->k);
	*f->ret = ok;
}

/* the numbers of an RSA public key, kept in k[i..i+1] */
static void
rsapk2pub(RSApub* p, Keyring_RSApk* pk, void **k, int i)
{
	if(pk == H)
		error(exNilref);
	memset(p, 0, sizeof(*p));
	p->n = keptnum(k, i, pk->n);
	p->ek = keptnum(k, i+1, pk->ek);
	modulusok(p->n);
	exponentok(p->ek);
}

/* an RSA secret key's numbers, kept in k[1..8] */
static void
rsask2priv(RSApriv* p, Keyring_RSAsk* sk, void **k)
{
	if(sk == H || sk->pk == H)
		error(exNilref);
	rsapk2pub(&p->pub, sk->pk, k, 1);
	p->dk = keptnum(k, 3, sk->dk);
	p->p = keptnum(k, 4, sk->p);
	p->q = keptnum(k, 5, sk->q);
	p->kp = keptnum(k, 6, sk->kp);
	p->kq = keptnum(k, 7, sk->kq);
	p->c2 = keptnum(k, 8, sk->c2);
	modulusok(p->p);
	modulusok(p->q);
	exponentok(p->kp);
	exponentok(p->kq);
}

static void
rsapriv2sk(Keyring_RSAsk* sk, RSApriv* p)
{
	Keyring_RSApk* pk;

	pk = sk->pk;
	pk->n = ipcopymp(p->pub.n);
	pk->ek = ipcopymp(p->pub.ek);
	sk->dk = ipcopymp(p->dk);
	sk->p = ipcopymp(p->p);
	sk->q = ipcopymp(p->q);
	sk->kp = ipcopymp(p->kp);
	sk->kq = ipcopymp(p->kq);
	sk->c2 = ipcopymp(p->c2);
}

void
RSApk_encrypt(void *fp)
{
	F_RSApk_encrypt *f;
	Keyring_RSApk *pk;
	RSApub p;
	mpint *m, *o;
	void *v, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	pk = f->k;
	k = keep(&f->k, 2);
	rsapk2pub(&p, pk, k, 1);
	m = keynum(f->m);
	release();
	o = rsaencrypt(&p, m, nil);
	acquire();
	unkeep(&f->k);
	/* nil for an m outside 0..n-1 (RFC 8017 5.1.1) */
	if(o != nil)
		*f->ret = newIPint(o);
}

void
RSAsk_gen(void *fp)
{
	F_RSAsk_gen *f;
	Keyring_RSAsk *sk;
	RSApriv *p;
	Cres *c;
	void *v;

	f = fp;
	genbits(f->nlen, MinRSAbits, Maxgenbits);
	genbits(f->elen, 1, f->nlen);
	release();
	for(;;){
		p = rsagen(f->nlen, f->elen, f->nrep);
		if(mpsignif(p->pub.n) == f->nlen)
			break;
		rsaprivfree(p);
	}
	acquire();
	c = cres(p, (void(*)(void*))rsaprivfree);
	sk = newthing(TRSAsk, 0);
	sk->pk = newthing(TRSApk, 0);
	rsapriv2sk(sk, p);
	destroy(c);
	v = *f->ret;
	*f->ret = sk;
	destroy(v);
}

void
RSAsk_fill(void *fp)
{
	F_RSAsk_fill *f;
	Keyring_RSAsk *sk;
	RSApriv *p;
	mpint *n, *e, *d, *pp, *q;
	Cres *c;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);
	/*
	 * the numbers are the call's own arguments, which the frame
	 * holds (the parts were looked at with the VM let go)
	 */
	n = keynum(f->n);
	e = keynum(f->e);
	d = keynum(f->d);
	pp = keynum(f->p);
	q = keynum(f->q);
	release();
	p = rsafill(n, e, d, pp, q);
	acquire();
	if(p == nil)
		return;
	c = cres(p, (void(*)(void*))rsaprivfree);
	sk = newthing(TRSAsk, 0);
	sk->pk = newthing(TRSApk, 0);
	rsapriv2sk(sk, p);
	destroy(c);
	*f->ret = sk;
}

void
RSAsk_decrypt(void *fp)
{
	F_RSAsk_decrypt *f;
	Keyring_RSAsk *sk;
	RSApriv p;
	mpint *m, *o;
	void *v, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = f->k;
	k = keep(&f->k, 8);
	rsask2priv(&p, sk, k);
	m = keynum(f->m);
	release();
	o = rsadecrypt(&p, m, nil);
	acquire();
	unkeep(&f->k);
	/* nil for an m outside 0..n-1, or a key whose parts do not agree */
	if(o != nil)
		*f->ret = newIPint(o);
}

void
RSAsk_sign(void *fp)
{
	F_RSAsk_sign *f;
	Keyring_RSAsig *sig;
	Keyring_RSAsk *sk;
	RSApriv p;
	mpint *m, *s;
	Cres *c;
	void *v, **k;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	sk = f->k;
	k = keep(&f->k, 8);
	rsask2priv(&p, sk, k);
	m = keynum(f->m);
	release();
	s = rsadecrypt(&p, m, nil);
	acquire();
	unkeep(&f->k);
	/* see RSAsk_decrypt: no signature */
	if(s == nil)
		return;
	c = cres(s, (void(*)(void*))mpfree);
	sig = newthing(TRSAsig, 0);
	c->p = nil;	/* newIPint frees the number if it raises */
	destroy(c);
	sig->n = newIPint(s);
	*f->ret = sig;
}

void
RSApk_verify(void *fp)
{
	F_RSApk_verify *f;
	Keyring_RSApk *pk;
	RSApub p;
	mpint *sig, *m, *t;
	void **k;
	int ok;

	f = fp;
	*f->ret = 0;
	if(f->m == H || f->sig == H)
		return;
	pk = f->k;
	k = keep(&f->k, 3);
	rsapk2pub(&p, pk, k, 1);
	sig = keptnum(k, 3, f->sig->n);
	m = keynum(f->m);
	release();
	t = rsaencrypt(&p, sig, nil);
	/* nil for a signature outside 0..n-1 (RFC 8017 5.2.2): none */
	ok = t != nil && mpcmp(t, m) == 0;
	mpfree(t);
	acquire();
	unkeep(&f->k);
	*f->ret = ok;
}

void
Keyring_IPint_random(void *fp)
{
	F_IPint_random *f;
	mpint *b;
	void *v;

	f = fp;
	v = *f->ret;
	*f->ret = H;
	destroy(v);

	genbits(f->maxbits, 0, Maxrandbits);
	release();
	b = mprand(f->maxbits, genrandom, nil);
	acquire();
	*f->ret = newIPint(b);
}

/*
 *  X25519 (Curve25519 ECDH)
 */
void
Keyring_x25519(void *fp)
{
	F_Keyring_x25519 *f;
	uchar out[32];
	void *r;
	int i, nz;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->scalar == H || f->scalar->len != 32)
		error(exBadKey);
	if(f->point == H || f->point->len != 32)
		error(exBadKey);

	x25519(out, f->scalar->data, f->point->data);
	nz = 0;
	for(i = 0; i < nelem(out); i++)
		nz |= out[i];
	if(nz == 0){
		secureZero(out, sizeof(out));
		return;
	}

	*f->ret = mem2array(out, 32);
	secureZero(out, sizeof(out));	/* (a memset here is one compilers drop) */
}

void
Keyring_x25519_base(void *fp)
{
	F_Keyring_x25519_base *f;
	uchar out[32];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->scalar == H || f->scalar->len != 32)
		error(exBadKey);

	x25519_base(out, f->scalar->data);

	*f->ret = mem2array(out, 32);
}

/*
 *  ChaCha20-Poly1305 AEAD
 */
void
Keyring_ccpolyencrypt(void *fp)
{
	F_Keyring_ccpolyencrypt *f;
	uchar tag[16];
	uchar *buf;
	int ndat;

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(f->dat == H)
		return;
	if(f->key == H || f->key->len != 32)
		error(exBadKey);
	if(f->nonce == H || f->nonce->len != 12)
		error(exBadIvec);

	ndat = f->dat->len;

	buf = malloc(ndat);
	if(buf == nil)
		error(exNomem);
	memmove(buf, f->dat->data, ndat);

	ccpoly_encrypt(buf, ndat,
		f->aad != H ? f->aad->data : nil,
		f->aad != H ? f->aad->len : 0,
		tag, f->key->data, f->nonce->data);

	f->ret->t0 = mem2array(buf, ndat);
	f->ret->t1 = mem2array(tag, 16);
	free(buf);
}

void
Keyring_ccpolydecrypt(void *fp)
{
	F_Keyring_ccpolydecrypt *f;
	uchar *buf;
	int ndat;
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->dat == H)
		return;
	if(f->tag == H || f->tag->len != 16)
		error(exBadDigest);
	if(f->key == H || f->key->len != 32)
		error(exBadKey);
	if(f->nonce == H || f->nonce->len != 12)
		error(exBadIvec);

	ndat = f->dat->len;

	buf = malloc(ndat);
	if(buf == nil)
		error(exNomem);
	memmove(buf, f->dat->data, ndat);

	if(ccpoly_decrypt(buf, ndat,
		f->aad != H ? f->aad->data : nil,
		f->aad != H ? f->aad->len : 0,
		f->tag->data, f->key->data, f->nonce->data) != 0){
		/* authentication failed - return nil */
		free(buf);
		return;
	}

	*f->ret = mem2array(buf, ndat);
	free(buf);
}

/*
 *  P-256 (secp256r1) ECDH + ECDSA
 */
void
Keyring_p256_keygen(void *fp)
{
	F_Keyring_p256_keygen *f;
	Heap *h;
	XECpoint *ep;
	uchar priv[32];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	h = heap(TECpoint);
	ep = H2D(XECpoint*, h);

	if(p256_keygen(priv, &ep->point) != 0){
		destroy(ep);
		return;
	}

	f->ret->t0 = mem2array(priv, 32);
	f->ret->t1 = (Keyring_ECpoint*)ep;
	secureZero(priv, 32);
}

void
Keyring_p256_ecdh(void *fp)
{
	F_Keyring_p256_ecdh *f;
	XECpoint *ep;
	uchar shared[32];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->priv == H || f->priv->len != 32)
		error(exBadKey);
	if(f->pub == H)
		error(exBadPK);

	ep = checktype(f->pub, TECpoint, exBadPK, 0);

	if(p256_ecdh(shared, f->priv->data, &ep->point) != 0)
		return;

	*f->ret = mem2array(shared, 32);
	secureZero(shared, 32);
}

void
Keyring_p256_ecdsa_sign(void *fp)
{
	F_Keyring_p256_ecdsa_sign *f;
	uchar sig[64];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->priv == H || f->priv->len != 32)
		error(exBadKey);
	if(f->hash == H || f->hash->len == 0)
		error(exBadDigest);

	if(p256_ecdsa_sign(sig, f->priv->data, f->hash->data, f->hash->len) != 0)
		return;

	*f->ret = mem2array(sig, 64);
}

void
Keyring_p256_ecdsa_verify(void *fp)
{
	F_Keyring_p256_ecdsa_verify *f;
	XECpoint *ep;

	f = fp;
	*f->ret = 0;

	if(f->pub == H)
		return;
	if(f->hash == H || f->hash->len == 0)
		return;
	if(f->sig == H || f->sig->len != 64)
		return;

	ep = checktype(f->pub, TECpoint, exBadPK, 0);

	*f->ret = p256_ecdsa_verify(f->sig->data, &ep->point, f->hash->data, f->hash->len);
}

void
Keyring_p256_make_point(void *fp)
{
	F_Keyring_p256_make_point *f;
	Heap *h;
	XECpoint *ep;

	f = fp;
	destroy(*f->ret);
	*f->ret = H;

	if(f->pubkey == H || f->pubkey->len != 65 || f->pubkey->data[0] != 0x04)
		return;

	h = heap(TECpoint);
	ep = H2D(XECpoint*, h);

	memmove(ep->point.x, f->pubkey->data + 1, 32);
	memmove(ep->point.y, f->pubkey->data + 33, 32);

	*f->ret = (Keyring_ECpoint*)ep;
}

void
Keyring_p256_point_bytes(void *fp)
{
	F_Keyring_p256_point_bytes *f;
	XECpoint *ep;
	uchar outbuf[65];

	f = fp;
	destroy(*f->ret);
	*f->ret = H;

	if(f->pub == H)
		return;

	ep = checktype(f->pub, TECpoint, exBadPK, 0);

	outbuf[0] = 0x04;
	memmove(outbuf + 1, ep->point.x, 32);
	memmove(outbuf + 33, ep->point.y, 32);

	*f->ret = mem2array(outbuf, 65);
}

/*
 *  P-384 (secp384r1) ECDSA verify only
 *  Uses raw byte arrays instead of an ADT.
 */
void
Keyring_p384_ecdsa_verify(void *fp)
{
	F_Keyring_p384_ecdsa_verify *f;
	ECpoint384 pt;

	f = fp;
	*f->ret = 0;

	/* pubkey must be 97 bytes: 0x04 + x[48] + y[48] */
	if(f->pubkey == H || f->pubkey->len != 97 || f->pubkey->data[0] != 0x04)
		return;
	if(f->hash == H || f->hash->len == 0)
		return;
	if(f->sig == H || f->sig->len != 96)
		return;

	memmove(pt.x, f->pubkey->data + 1, 48);
	memmove(pt.y, f->pubkey->data + 49, 48);

	*f->ret = p384_ecdsa_verify(f->sig->data, &pt, f->hash->data, f->hash->len);
}

void
Keyring_p384_keygen(void *fp)
{
	F_Keyring_p384_keygen *f;
	uchar priv[48], pubbuf[97];
	ECpoint384 pub;

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(p384_keygen(priv, &pub) != 0)
		error(exBadKey);

	pubbuf[0] = 0x04;	/* SEC1 uncompressed point */
	memmove(pubbuf + 1, pub.x, 48);
	memmove(pubbuf + 49, pub.y, 48);
	f->ret->t0 = mem2array(priv, 48);
	f->ret->t1 = mem2array(pubbuf, 97);
	secureZero(priv, 48);
}

void
Keyring_p384_ecdh(void *fp)
{
	F_Keyring_p384_ecdh *f;
	ECpoint384 peer;
	uchar shared[48];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->priv == H || f->priv->len != 48)
		error(exBadKey);
	if(f->pub == H || f->pub->len != 97 || f->pub->data[0] != 0x04)
		error(exBadPK);

	memmove(peer.x, f->pub->data + 1, 48);
	memmove(peer.y, f->pub->data + 49, 48);

	/* p384_ecdh validates the peer point (on-curve, non-identity) */
	if(p384_ecdh(shared, f->priv->data, &peer) != 0)
		error(exBadPK);

	*f->ret = mem2array(shared, 48);
	secureZero(shared, 48);
}

/*
 *  secp256k1 ECDSA (Ethereum/Bitcoin)
 *  Uses raw byte arrays: priv[32], pub[65], sig[65]
 */
void
Keyring_secp256k1_keygen(void *fp)
{
	F_Keyring_secp256k1_keygen *f;
	uchar priv[32], pub[65];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(secp256k1_keygen(priv, pub) != 0)
		return;

	f->ret->t0 = mem2array(priv, 32);
	f->ret->t1 = mem2array(pub, 65);
	secureZero(priv, 32);
}

void
Keyring_secp256k1_pubkey(void *fp)
{
	F_Keyring_secp256k1_pubkey *f;
	uchar pub[65];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->priv == H || f->priv->len != 32)
		error(exBadKey);

	if(secp256k1_pubkey(pub, f->priv->data) != 0)
		return;	/* out-of-range key: return nil */
	*f->ret = mem2array(pub, 65);
}

void
Keyring_secp256k1_sign(void *fp)
{
	F_Keyring_secp256k1_sign *f;
	uchar sig[65];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->priv == H || f->priv->len != 32)
		error(exBadKey);
	if(f->hash == H || f->hash->len == 0)
		error(exBadDigest);

	if(secp256k1_sign(sig, f->priv->data, f->hash->data, f->hash->len) != 0)
		return;

	*f->ret = mem2array(sig, 65);
}

void
Keyring_secp256k1_recover(void *fp)
{
	F_Keyring_secp256k1_recover *f;
	uchar pub[65];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->hash == H || f->hash->len == 0)
		error(exBadDigest);
	if(f->sig == H || f->sig->len != 65)
		return;

	if(secp256k1_recover(pub, f->hash->data, f->hash->len, f->sig->data) != 0)
		return;

	*f->ret = mem2array(pub, 65);
}

/*
 *  Keccak-256 (Ethereum variant, domain separator 0x01)
 */
void
Keyring_keccak256(void *fp)
{
	F_Keyring_keccak256 *f;
	uchar *cbuf;
	int n;

	f = fp;
	*f->ret = 0;

	if(f->buf == H || f->digest == H)
		return;

	n = digestcount(f->buf, f->n);
	if(f->digest->len < 32)
		error(exBadDigest);

	cbuf = f->buf->data;
	keccak256(cbuf, n, f->digest->data);
	*f->ret = 32;
}

/*
 *  Ed25519 raw sign (RFC 8032)
 *  Takes 32-byte seed + message, returns 64-byte signature
 */
void
Keyring_ed25519_sign(void *fp)
{
	F_Keyring_ed25519_sign *f;
	uchar sig[64];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->seed == H || f->seed->len != 32)
		return;

	ed25519_raw_sign(sig, f->seed->data,
		f->msg == H ? nil : f->msg->data,
		f->msg == H ? 0 : f->msg->len);

	*f->ret = mem2array(sig, 64);
}

/*
 *  Ed25519 raw verify (RFC 8032)
 *  Takes 32-byte pk + message + 64-byte signature, returns 0/1
 */
void
Keyring_ed25519_verify(void *fp)
{
	F_Keyring_ed25519_verify *f;

	f = fp;
	*f->ret = 0;

	if(f->pk == H || f->pk->len != 32)
		return;
	if(f->sig == H || f->sig->len != 64)
		return;

	*f->ret = ed25519_raw_verify(f->sig->data, f->pk->data,
		f->msg == H ? nil : f->msg->data,
		f->msg == H ? 0 : f->msg->len);
}

/*
 *  ML-KEM (FIPS 203) post-quantum key encapsulation
 */
void
Keyring_mlkem768_keygen(void *fp)
{
	F_Keyring_mlkem768_keygen *f;
	uchar pk[MLKEM768_PKLEN], sk[MLKEM768_SKLEN];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(mlkem768_keygen(pk, sk) != 0){
		secureZero(pk, sizeof(pk));
		secureZero(sk, sizeof(sk));
		error(exNomem);
	}

	f->ret->t0 = mem2array(pk, MLKEM768_PKLEN);
	f->ret->t1 = mem2array(sk, MLKEM768_SKLEN);
	secureZero(sk, MLKEM768_SKLEN);
}

void
Keyring_mlkem768_encaps(void *fp)
{
	F_Keyring_mlkem768_encaps *f;
	uchar ct[MLKEM768_CTLEN], ss[MLKEM_SSLEN];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(f->pk == H || f->pk->len != MLKEM768_PKLEN)
		error(exBadKey);
	if(mlkem768_checkek(f->pk->data) != 0)
		error(exBadKey);

	if(mlkem768_encaps(ct, ss, f->pk->data) != 0){
		secureZero(ct, sizeof(ct));
		secureZero(ss, sizeof(ss));
		error(exNomem);
	}

	f->ret->t0 = mem2array(ct, MLKEM768_CTLEN);
	f->ret->t1 = mem2array(ss, MLKEM_SSLEN);
	secureZero(ss, MLKEM_SSLEN);
}

void
Keyring_mlkem768_decaps(void *fp)
{
	F_Keyring_mlkem768_decaps *f;
	uchar ss[MLKEM_SSLEN];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->sk == H || f->sk->len != MLKEM768_SKLEN)
		error(exBadKey);
	if(f->ct == H || f->ct->len != MLKEM768_CTLEN)
		error(exBadKey);
	if(mlkem768_checkdk(f->sk->data) != 0)
		error(exBadKey);

	if(mlkem768_decaps(ss, f->ct->data, f->sk->data) != 0){
		secureZero(ss, sizeof(ss));
		error(exNomem);
	}

	*f->ret = mem2array(ss, MLKEM_SSLEN);
	secureZero(ss, MLKEM_SSLEN);
}

void
Keyring_mlkem1024_keygen(void *fp)
{
	F_Keyring_mlkem1024_keygen *f;
	uchar pk[MLKEM1024_PKLEN], sk[MLKEM1024_SKLEN];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(mlkem1024_keygen(pk, sk) != 0){
		secureZero(pk, sizeof(pk));
		secureZero(sk, sizeof(sk));
		error(exNomem);
	}

	f->ret->t0 = mem2array(pk, MLKEM1024_PKLEN);
	f->ret->t1 = mem2array(sk, MLKEM1024_SKLEN);
	secureZero(sk, MLKEM1024_SKLEN);
}

void
Keyring_mlkem1024_encaps(void *fp)
{
	F_Keyring_mlkem1024_encaps *f;
	uchar ct[MLKEM1024_CTLEN], ss[MLKEM_SSLEN];

	f = fp;
	destroy(f->ret->t0);
	destroy(f->ret->t1);
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(f->pk == H || f->pk->len != MLKEM1024_PKLEN)
		error(exBadKey);
	if(mlkem1024_checkek(f->pk->data) != 0)
		error(exBadKey);

	if(mlkem1024_encaps(ct, ss, f->pk->data) != 0){
		secureZero(ct, sizeof(ct));
		secureZero(ss, sizeof(ss));
		error(exNomem);
	}

	f->ret->t0 = mem2array(ct, MLKEM1024_CTLEN);
	f->ret->t1 = mem2array(ss, MLKEM_SSLEN);
	secureZero(ss, MLKEM_SSLEN);
}

void
Keyring_mlkem1024_decaps(void *fp)
{
	F_Keyring_mlkem1024_decaps *f;
	uchar ss[MLKEM_SSLEN];
	void *r;

	f = fp;
	r = *f->ret;
	*f->ret = H;
	destroy(r);

	if(f->sk == H || f->sk->len != MLKEM1024_SKLEN)
		error(exBadKey);
	if(f->ct == H || f->ct->len != MLKEM1024_CTLEN)
		error(exBadKey);
	if(mlkem1024_checkdk(f->sk->data) != 0)
		error(exBadKey);

	if(mlkem1024_decaps(ss, f->ct->data, f->sk->data) != 0){
		secureZero(ss, sizeof(ss));
		error(exNomem);
	}

	*f->ret = mem2array(ss, MLKEM_SSLEN);
	secureZero(ss, MLKEM_SSLEN);
}
