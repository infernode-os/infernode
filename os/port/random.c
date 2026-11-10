/*
 * Random numbers for everything that wants them unpredictable: keys
 * (libsec's generators call genrandom, prng and prngtry by name),
 * #c/random, #c/notquiterandom and truerand. One generator serves them
 * all, and every board's kernel has this one.
 *
 * Imported from upstream Inferno os/port/random.c and since rewritten
 * three times. Upstream stirred a pool with clock jitter and handed out
 * what was in it. #1051 made the rule that a secret comes only from a
 * hardware generator, and kept it by reading the generator for every
 * byte asked for: at the hardware's speed (an RNG200 gives about
 * 190 KB/s), with nothing behind it, and a key made while the generator
 * had nothing waited holding the Dis VM, so every program on it stopped
 * too. So a deterministic generator came to stand between the hardware
 * and every reader, as in Linux, the BSDs and 9front; it was ChaCha20,
 * which no NIST or CNSA list admits as a generator. It is now:
 *
 *	HMAC_DRBG with SHA-512 (NIST SP 800-90A Rev. 1, 10.1.2), at its
 *	full 256-bit strength, without prediction resistance: each
 *	request is a Generate of at most 64K (the specification allows
 *	2^19 bits), followed by its Update, so the state that made a
 *	request's output is gone when it returns (backtracking
 *	resistance), as ChaCha20's fast key erasure was.
 *
 *	It is instantiated from the hardware alone: Seedbytes of entropy
 *	input and Noncebytes of nonce, both read from the generator, with
 *	a personalization string naming this generator. Until they have
 *	come NOTHING is returned: a reader waits, saying why on the console
 *	every five seconds. The RNG200 is taken to give 4 bits of entropy
 *	in a byte, so Seedbytes, 64, carry the 256 bits the strength needs.
 *
 *	It reseeds from the hardware (Seedbytes, SP 800-90A's Reseed) every
 *	Reseedms or Reseedbytes, whichever comes first, far within the
 *	specification's 2^48 requests, so a state that leaked is of use for
 *	a second at most. When the hardware has nothing at a reseed, the
 *	old state goes on serving -- it is still a secret no one has seen
 *	-- but only for Stalems: after that a generator that has stopped is
 *	taken to have broken, and readers wait for it as they waited at
 *	boot.
 *
 *	The hardware's bytes pass SP 800-90B's two continuous health tests
 *	(4.4.1 repetition count, 4.4.2 adaptive proportion, at the 4 bits a
 *	byte claimed above and a false alarm of one in 2^20) before they
 *	are used, and seeds that are one 32-bit word over and over, or that
 *	repeat the last seed, are not taken: an unmapped register or a
 *	stuck FIFO reads like that, and the hardware's own tests do not see
 *	what a driver does with its words.
 *
 *	HMAC_DRBG is checked against NIST's CAVP vectors (HMAC_DRBG.rsp,
 *	SHA-512, without and with a reseed) before its first use. A kernel
 *	built wrong would otherwise make a stream that looks random and is
 *	not the one specified; this one panics instead.
 *
 *	A reader that waits lets go of the Dis VM while it does, when it
 *	has it (a key made by a Keyring builtin), so the rest of the
 *	machine goes on.
 *
 * The board's hwrandom(p, n) returns how many real bytes it had (it
 * may be short, and it must not spin), 0 when the generator is dry
 * for now, and -1 when this machine has no generator at all --
 * hwrandom(nil, 0) asks only that. It never makes bytes up.
 *
 * With no generator no secret is made: everything here waits. The
 * kernel still boots and its network still works, since nrand -- port
 * numbers and TCP sequence numbers, not secrets, and an LCG over the
 * clock since upstream -- never waits (devcons.c's seedrand).
 *
 * An emulator with no generator can have a counter instead, when its
 * boot command line holds the word "insecurerandom", which says in so
 * many words what the boot is; tests/host/baremetal_test.sh passes it
 * to the QEMU machines that have no generator. The counter then seeds
 * this generator, whose output is exactly as predictable as the
 * counter, and the console says so in capitals when it is first used.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"mp.h"
#include	"libsec.h"
#include	<interp.h>

enum
{
	Seedbytes	= 64,		/* entropy input: 256 bits at 4 bits a byte */
	Noncebytes	= 16,		/* the nonce, at instantiation */
	Outlen		= SHA512dlen,	/* HMAC_DRBG's K and V */
	Reseedms	= 1000,
	Reseedbytes	= 1<<20,
	Retryms		= 100,		/* a dry generator is asked again no sooner */
	Stalems		= 10*60*1000,	/* the longest the old state serves while the generator is dry */
	Chunk		= 64*1024,	/* the most one Generate gives (2^19 bits) */
	Tellms		= 5000,

	/* SP 800-90B 4.4: H = 4 bits a byte, alpha = 2^-20 */
	Rctcutoff	= 6,		/* 1 + ceil(20/H) */
	Aptwindow	= 512,
	Aptcutoff	= 62,		/* critbinom(512, 2^-4, 1-2^-20) */
};

static char personal[] = "InferNode os/port/random.c HMAC_DRBG SHA-512";

static struct
{
	QLock	q;
	uchar	k[Outlen];
	uchar	v[Outlen];
	uvlong	counter;	/* SP 800-90A's reseed_counter */
	int	seeded;		/* 0 never, 1 by the hardware, 2 by the counter (insecurerandom) */
	vlong	seedms;		/* when last reseeded */
	int	dry;		/* the hardware had no reseed to give at triedms */
	vlong	triedms;
	uvlong	since;		/* bytes given since the last reseed */
	uchar	last[SHA512dlen];	/* the hash of the last seed, to see one repeated */
	int	katdone;
	ulong	reseeds;
	ulong	refused;	/* seeds not taken */

	/* SP 800-90B's continuous tests, over every byte the hardware gives */
	int	rctlast;	/* the last byte, or -1 */
	int	rctrun;
	int	aptfirst;	/* the window's first byte, or -1 */
	int	aptcount;
	int	aptn;
} drbg = { .rctlast = -1, .aptfirst = -1 };

static int	insecureok(void);
static int	weakrandom(uchar*, int);

static vlong
nowms(void)
{
	return TK2MS((vlong)MACHP(0)->ticks);
}

/* not a dead store the compiler may drop */
static void
wipe(void *a, int n)
{
	volatile uchar *p;

	for(p = a; n > 0; n--)
		*p++ = 0;
}

/*
 * HMAC-SHA-512 (RFC 2104) of the pieces p[0..n-1], one after another,
 * its digest states on the stack: libsec's hmac_x allocates the outer
 * one, and this runs with drbg.q held, where an allocation could wait
 * or fail.
 */
static void
hmac(uchar *key, uchar **p, int *len, int n, uchar *out)
{
	SHA512state s;
	uchar pad[SHA512bsize], in[SHA512dlen];
	int i;

	memset(pad, 0x36, sizeof pad);
	for(i = 0; i < Outlen; i++)
		pad[i] ^= key[i];
	memset(&s, 0, sizeof s);
	sha512(pad, sizeof pad, nil, &s);
	for(i = 0; i < n; i++)
		if(len[i] > 0)
			sha512(p[i], len[i], nil, &s);
	sha512(nil, 0, in, &s);

	memset(pad, 0x5c, sizeof pad);
	for(i = 0; i < Outlen; i++)
		pad[i] ^= key[i];
	memset(&s, 0, sizeof s);
	sha512(pad, sizeof pad, nil, &s);
	sha512(in, sizeof in, out, &s);
	wipe(pad, sizeof pad);
	wipe(in, sizeof in);
	wipe(&s, sizeof s);
}

/* V = HMAC(K, V) */
static void
nextv(uchar *k, uchar *v)
{
	uchar *p[1];
	int len[1];

	p[0] = v;
	len[0] = Outlen;
	hmac(k, p, len, 1, v);
}

/*
 * SP 800-90A 10.1.2.2, HMAC_DRBG_Update, of the state k and v with the
 * provided data, which is the pieces d0..d2 one after another.
 */
static void
update(uchar *k, uchar *v, uchar *d0, int n0, uchar *d1, int n1, uchar *d2, int n2)
{
	static uchar zero[1] = {0x00}, one[1] = {0x01};
	uchar *p[5];
	int len[5];

	p[0] = v;	len[0] = Outlen;
	p[1] = zero;	len[1] = 1;
	p[2] = d0;	len[2] = n0;
	p[3] = d1;	len[3] = n1;
	p[4] = d2;	len[4] = n2;
	hmac(k, p, len, 5, k);		/* K = HMAC(K, V || 0x00 || provided) */
	nextv(k, v);
	if(n0 + n1 + n2 == 0)
		return;
	p[0] = v;	/* the new V */
	p[1] = one;
	hmac(k, p, len, 5, k);		/* K = HMAC(K, V || 0x01 || provided) */
	nextv(k, v);
}

/* 10.1.2.3, Instantiate: K = 0x00.., V = 0x01.., Update(entropy || nonce || personal) */
static void
instantiate(uchar *k, uchar *v, uchar *e, int ne, uchar *nonce, int nn, uchar *ps, int nps)
{
	memset(k, 0x00, Outlen);
	memset(v, 0x01, Outlen);
	update(k, v, e, ne, nonce, nn, ps, nps);
}

/* 10.1.2.4, Reseed: Update(entropy || additional), none here */
static void
reseedwith(uchar *k, uchar *v, uchar *e, int ne)
{
	update(k, v, e, ne, nil, 0, nil, 0);
}

/* 10.1.2.5, Generate, n <= Chunk, no additional input; Update(nil) after */
static void
generatewith(uchar *k, uchar *v, uchar *p, int n)
{
	int m;

	while(n > 0){
		nextv(k, v);
		m = n < Outlen ? n : Outlen;
		memmove(p, v, m);
		p += m;
		n -= m;
	}
	update(k, v, nil, 0, nil, 0, nil, 0);
}

static int
unhex(char *s, uchar *b)
{
	int n, d, i;

	for(n = 0; s[0] && s[1]; s += 2, n++){
		b[n] = 0;
		for(i = 0; i < 2; i++){
			d = s[i];
			if(d >= '0' && d <= '9')
				d -= '0';
			else if(d >= 'a' && d <= 'f')
				d -= 'a' - 10;
			else
				return -1;
			b[n] = b[n]<<4 | d;
		}
	}
	return n;
}

/*
 * NIST CAVP drbgtestvectors, HMAC_DRBG.rsp, [SHA-512],
 * PredictionResistance False, 256-bit entropy, 128-bit nonce, no
 * personalization or additional input, 2048 bits returned: COUNT 0 of
 * drbgvectors_no_reseed, and COUNT 0 of drbgvectors_pr_false (a reseed
 * between instantiation and the first Generate). The vector's bits are
 * the second Generate's.
 */
static struct {
	char	*entropy;
	char	*nonce;
	char	*reseed;
	char	*want;
} kats[] = {
	{
	"35049f389a33c0ecb1293238fd951f8ffd517dfde06041d32945b3e26914ba15",
	"f7328760be6168e6aa9fb54784989a11",
	nil,
	"e76491b0260aacfded01ad39fbf1a66a88284caa5123368a2ad9330ee48335e3c9c9ba90e6cbc9429962d60c1a6661edcfaa31d972b8264b9d4562cf18494128a092c17a8da6f3113e8a7edfcd4427082bd390675e9662408144971717303d8dc352c9e8b95e7f35fa2ac9f549b292bc7c4bc7f01ee0a577859ef6e82d79ef23892d167c140d22aac32b64ccdfeee2730528a38763b24227f91ac3ffe47fb11538e435307e77481802b0f613f370ffb0dbeab774fe1efbb1a80d01154a9459e73ad361108bbc86b0914f095136cbe634555ce0bb263618dc5c367291ce0825518987154fe9ecb052b3f0a256fcc30cc14572531c9628973639beda456f2bddf6",
	},
	{
	"48c121b18733af15c27e1dd9ba66a9a81a5579cdba0f5b657ec53c2b9e90bbf6",
	"bbb7c777428068fad9970891f879b1af",
	"e0ffefdadb9ccf990504d568bdb4d862cbe17ccce6e22dfcab8b4804fd21421a",
	"05da6aac7d980da038f65f392841476d37fe70fbd3e369d1f80196e66e54b8fadb1d60e1a0f3d4dc173769d75fc3410549d7a843270a54a068b4fe767d7d9a59604510a875ad1e9731c8afd0fd50b825e2c50d062576175106a9981be37e02ec7c5cd0a69aa0ca65bddaee1b0de532e10cfa1f5bf6a026e47379736a099d6750ab121dbe3622b841baf8bdcbe875c85ba4b586b8b5b57b0fecbec08c12ff2a9453c47c6e32a52103d972c62ab9affb8e728a31fcefbbccc556c0f0a35f4b10ace2d96b906e36cbb72233201e536d3e13b045187b417d2449cad1edd192e061f12d22147b0a176ea8d9c4c35404395b6502ef333a813b6586037479e0fa3c6a23",
	},
};

static void
drbgkat(void)
{
	uchar k[Outlen], v[Outlen], e[32], nonce[16], r[32], want[256], out[256+3], *o;
	int i;

	for(i = 0; i < nelem(kats); i++){
		unhex(kats[i].entropy, e);
		unhex(kats[i].nonce, nonce);
		unhex(kats[i].want, want);
		instantiate(k, v, e, 32, nonce, 16, nil, 0);
		if(kats[i].reseed != nil){
			unhex(kats[i].reseed, r);
			reseedwith(k, v, r, 32);
		}
		o = out + 3;	/* not word-aligned, as a reader's buffer need not be */
		generatewith(k, v, o, 256);
		generatewith(k, v, o, 256);
		if(memcmp(o, want, 256) != 0)
			panic("random: HMAC_DRBG does not give NIST's CAVP vector %d; this kernel cannot make keys", i);
	}
	wipe(k, sizeof k);
	wipe(v, sizeof v);
}

/* qlocked: n bytes, Chunk at most a Generate */
static void
fill(uchar *p, int n)
{
	int m;

	while(n > 0){
		m = n;
		if(m > Chunk)
			m = Chunk;
		generatewith(drbg.k, drbg.v, p, m);
		drbg.counter++;
		drbg.since += m;
		p += m;
		n -= m;
	}
}

/*
 * qlocked: SP 800-90B's continuous tests on bytes the hardware gave.
 * 0 when they pass; -1 when the source failed, which is said once a
 * hundred times and the bytes not used.
 */
static int
healthy(uchar *p, int n)
{
	int i, b, bad;

	bad = 0;
	for(i = 0; i < n; i++){
		b = p[i];
		/* 4.4.1 repetition count */
		if(b == drbg.rctlast){
			if(++drbg.rctrun >= Rctcutoff)
				bad = 1;
		}else{
			drbg.rctlast = b;
			drbg.rctrun = 1;
		}
		/* 4.4.2 adaptive proportion */
		if(drbg.aptfirst < 0 || drbg.aptn >= Aptwindow){
			drbg.aptfirst = b;
			drbg.aptcount = 1;
			drbg.aptn = 1;
		}else{
			drbg.aptn++;
			if(b == drbg.aptfirst && ++drbg.aptcount >= Aptcutoff)
				bad = 1;
		}
	}
	return bad ? -1 : 0;
}

/*
 * qlocked: n bytes from the hardware. 1 when they came and passed;
 * 0 when the generator had none, or failed its tests (*why says which);
 * -1 when this machine has none, or 2 when there is none and the
 * command line allows the counter, which then gave them.
 */
static int
hwbytes(uchar *p, int n, char **why)
{
	int got, r;

	*why = nil;
	for(got = 0; got < n; got += r){
		r = hwrandom(p + got, n - got);
		if(r < 0 && insecureok()){
			weakrandom(p + got, n - got);
			return 2;
		}
		if(r <= 0)
			return r;
	}
	if(healthy(p, n) < 0){
		*why = "bytes that fail SP 800-90B's health tests";
		return 0;
	}
	return 1;
}

/*
 * qlocked: a seed from the hardware, instantiating the generator the
 * first time and reseeding it after. 1 when it was; 0 when the
 * generator had none to give, or gave what is refused above; -1 when
 * this machine has none.
 */
static int
reseed(void)
{
	uchar seed[Seedbytes+Noncebytes], h[SHA512dlen];
	u32int *w;
	char *why;
	int i, n, r, weak;

	n = drbg.seeded ? Seedbytes : Seedbytes+Noncebytes;
	r = hwbytes(seed, n, &why);
	if(r <= 0 && why == nil){
		wipe(seed, sizeof seed);
		return r;
	}
	weak = r == 2;
	if(!weak && why == nil){
		w = (u32int*)seed;
		for(i = 1; i < Seedbytes/4; i++)
			if(w[i] != w[0])
				break;
		sha512(seed, Seedbytes, h, nil);
		if(i == Seedbytes/4)
			why = "one word over and over";
		else if(memcmp(h, drbg.last, sizeof h) == 0)
			why = "the same seed twice";
		else
			memmove(drbg.last, h, sizeof h);
	}
	if(why != nil){
		if(drbg.refused++ % 100 == 0)
			print("random: the hardware generator gave %s; not used (%lud so far)\n", why, drbg.refused);
		wipe(seed, sizeof seed);
		wipe(h, sizeof h);
		return 0;
	}

	if(drbg.seeded == 0){
		instantiate(drbg.k, drbg.v, seed, Seedbytes, seed+Seedbytes, Noncebytes, (uchar*)personal, strlen(personal));
		drbg.seeded = weak ? 2 : 1;
	}else
		reseedwith(drbg.k, drbg.v, seed, Seedbytes);
	wipe(seed, sizeof seed);
	wipe(h, sizeof h);

	drbg.counter = 1;
	drbg.seedms = nowms();
	drbg.since = 0;
	drbg.reseeds++;
	return 1;
}

/*
 * qlocked: whether a request may be served now, reseeding first if it
 * is time. 1 yes; 0 no, the generator is dry; -1 no, there is none.
 */
static int
drbgready(void)
{
	vlong now;
	int r;

	if(!drbg.katdone){
		drbgkat();
		drbg.katdone = 1;
	}
	now = nowms();
	if(drbg.seeded){
		if(now - drbg.seedms < Reseedms && drbg.since < Reseedbytes)
			return 1;
		if(drbg.dry && now - drbg.triedms < Retryms && now - drbg.seedms < Stalems)
			return 1;
	}
	r = reseed();
	drbg.dry = r <= 0;
	if(r > 0)
		return 1;
	drbg.triedms = now;
	if(drbg.seeded && now - drbg.seedms < Stalems)
		return 1;
	return r;
}

/* whether this process has the Dis VM: a Keyring builtin making a key */
static int
holdsvm(void)
{
	return up != nil && up->type == Interp && up->iprog == nil;
}

/*
 * Wait a while for the generator, letting the VM go meanwhile, and
 * return the milliseconds waited. Where sleeping is not allowed, spin
 * a millisecond instead: every caller so far is a process, but nothing
 * here assumes it.
 */
static int
randomwait(void)
{
	int vm;

	if(up == nil || !islo()){
		microdelay(1000);
		return 1;
	}
	vm = holdsvm();
	if(vm){
		release();
		if(waserror()){
			acquire();
			nexterror();
		}
	}
	tsleep(&up->sleep, return0, 0, 100);
	if(vm){
		poperror();
		acquire();
	}
	return 100;
}

enum
{
	Forkey,
	Forpool,
};

static void
waiting(int why, int r, int n, int waited)
{
	if(why == Forkey){
		if(r < 0)
			print("random: there is NO ENTROPY SOURCE on this machine; %d bytes of key material "
				"have waited %d seconds and will not be made from anything else\n",
				n, waited/1000);
		else
			print("random: the hardware generator has produced nothing for %d seconds; still waiting for %d bytes\n",
				waited/1000, n);
	}else
		print("random: %s; a reader of #c/random has waited %d seconds\n",
			r < 0 ? "there is NO ENTROPY SOURCE on this machine, so it will go on waiting"
				: "the hardware generator has produced nothing",
			waited/1000);
}

/* waiting with drbg.q free, so other readers wait (and say so) too */
static void
generate(uchar *p, int n, int why)
{
	int r, waited, last;

	if(n <= 0)
		return;
	waited = 0;
	last = 0;
	for(;;){
		qlock(&drbg.q);
		r = drbgready();
		if(r > 0){
			fill(p, n);
			qunlock(&drbg.q);
			return;
		}
		qunlock(&drbg.q);
		waited += randomwait();
		if(waited - last >= Tellms){
			last = waited;
			waiting(why, r, n, waited);
		}
	}
}

/*
 * Nothing to start: the first request checks HMAC_DRBG and seeds. But a
 * boot that will hand out the counter says so now, not at the first
 * read, which may be long after the log anyone looks at.
 */
void
randominit(void)
{
	uchar b;

	if(hwrandom(nil, 0) < 0 && insecureok())
		weakrandom(&b, 1);
}

/*
 * #c/random. It and #c/notquiterandom are one generator now; the names
 * are upstream's, from when one was a pool of jitter and the other a
 * fast stream, and both stay for what reads them.
 */
ulong
randomread(void *xp, ulong n)
{
	generate(xp, n, Forpool);
	return n;
}

/*
 * genrandom -- n bytes of key material. libsec's key generators (RSA,
 * DSA, ElGamal, ECC, Ed25519, ML-KEM, ML-DSA, SLH-DSA) call it by name;
 * once, when it padded a short read from the hardware with zeros, they
 * made private keys ending in zeros without a word to anyone (#658).
 * It fails closed: it returns only once the generator above is keyed
 * from hardware, and says why on the console while it waits.
 */
void
genrandom(uchar *p, int n)
{
	generate(p, n, Forkey);
}

/*
 * libsec's entropy entry points, which its host build (prng.c) fills
 * from getentropy/urandom.
 */
void
prng(uchar *p, int n)
{
	genrandom(p, n);
}

/*
 * 0 with n real bytes, or -1 with none: libsec.h's contract, "-1 no
 * secure source (never aborts)". A generator that is only dry is
 * waited for, as genrandom waits; a machine with none says so at once,
 * which is what a caller that can do without is asking.
 */
int
prngtry(uchar *p, int n)
{
	if(hwrandom(nil, 0) < 0 && !insecureok())
		return -1;
	genrandom(p, n);
	return 0;
}

/*
 * "insecurerandom", as a whole word of the boot command line. Read
 * each time rather than once: this can be asked before a board has
 * read its command line, and it is asked only when there is no
 * generator, which is never on a board that works.
 */
static int
insecureok(void)
{
	char *p, *q, *w;
	int n;

	w = "insecurerandom";
	n = strlen(w);
	p = boardcmdline();
	if(p == nil)
		return 0;
	for(; *p != 0; p = q){
		while(*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')
			p++;
		for(q = p; *q != 0 && *q != ' ' && *q != '\t' && *q != '\r' && *q != '\n'; q++)
			;
		if(q - p == n && memcmp(p, w, n) == 0)
			return 1;
	}
	return 0;
}

/*
 * The counter an emulator with no generator gets, and only when its
 * command line asks for it (above). NOTHING CRYPTOGRAPHIC DONE WITH
 * IT IS WORTH ANYTHING, and the console is told so the first time.
 */
static int
weakrandom(uchar *p, int n)
{
	static Lock l;
	static u64int weak;
	static int warned;
	int i, warn;

	ilock(&l);
	for(i = 0; i < n; i++){
		weak = weak*6364136223846793005ULL + fastticks(nil) + 1442695040888963407ULL;
		p[i] = weak >> 56;
	}
	warn = !warned;
	warned = 1;
	iunlock(&l);
	if(warn)
		print("\nrandom: NO ENTROPY SOURCE, and the command line says insecurerandom:\n"
			"        random numbers on this boot are a counter. Keys made on it are PREDICTABLE.\n\n");
	return n;
}
