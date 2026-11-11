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
 *	HMAC_DRBG (libsec/hmacdrbg.c, which the emulator's generator uses
 *	too) is checked against NIST's CAVP vectors (HMAC_DRBG.rsp,
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
	Reseedms	= 1000,
	Reseedbytes	= 1<<20,
	Retryms		= 100,		/* a dry generator is asked again no sooner */
	Stalems		= 10*60*1000,	/* the longest the old state serves while the generator is dry */
	Chunk		= HMACDRBGmax,	/* the most one Generate gives (2^19 bits) */
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
	uchar	k[HMACDRBGlen];
	uchar	v[HMACDRBGlen];
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

/* qlocked: n bytes, Chunk at most a Generate */
static void
fill(uchar *p, int n)
{
	int m;

	while(n > 0){
		m = n;
		if(m > Chunk)
			m = Chunk;
		hmacdrbggen(drbg.k, drbg.v, p, m);
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
		hmacdrbginit(drbg.k, drbg.v, seed, Seedbytes, seed+Seedbytes, Noncebytes, (uchar*)personal, strlen(personal));
		drbg.seeded = weak ? 2 : 1;
	}else
		hmacdrbgreseed(drbg.k, drbg.v, seed, Seedbytes);
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
		if(hmacdrbgcheck() < 0)
			panic("random: HMAC_DRBG does not give NIST's CAVP vectors; this kernel cannot make keys");
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
