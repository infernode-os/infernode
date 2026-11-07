/*
 * Random numbers for everything that wants them unpredictable: keys
 * (libsec's generators call genrandom, prng and prngtry by name),
 * #c/random, #c/notquiterandom and truerand. One generator serves them
 * all, and every board's kernel has this one.
 *
 * Imported from upstream Inferno os/port/random.c and since rewritten
 * twice. Upstream stirred a pool with clock jitter and handed out what
 * was in it. #1051 made the rule that a secret comes only from a
 * hardware generator, and kept it by reading the generator for every
 * byte asked for. That kept the rule and nothing more: a reader got
 * whatever the hardware had just said, unwhitened, with nothing behind
 * it if the hardware were wrong in a way its own tests miss, at the
 * hardware's speed (an RNG200 gives about 190 KB/s); and a key made
 * while the generator had nothing waited holding the Dis VM, so every
 * program on it stopped too.
 *
 * So now a deterministic generator stands between the hardware and
 * every reader, as in Linux, the BSDs and 9front:
 *
 *	It is ChaCha20 (RFC 8439) with a 256-bit key, the construction
 *	libsec's hosted genrandom.c uses ("fast key erasure"): each
 *	request first takes 32 bytes of keystream as the next key, then
 *	uses what follows as its output and forgets the state it came
 *	from. What a request returned cannot be worked back from
 *	anything left in memory after it.
 *
 *	It is keyed from the hardware generator alone: 32 bytes of it,
 *	hashed with SHA-256 together with 32 bytes of the generator's
 *	own stream, so a reseed adds to what it had and never replaces
 *	it with something worse. Until the first 32 bytes have come,
 *	NOTHING is returned: a reader waits, saying why on the console
 *	every five seconds.
 *
 *	It reseeds from the hardware every Reseedms or Reseedbytes,
 *	whichever comes first, so a state that leaked is of use for a
 *	second at most. When the hardware has nothing at a reseed, the
 *	old key goes on serving -- it is still a secret no one has seen
 *	-- but only for Stalems: after that a generator that has stopped
 *	is taken to have broken, and readers wait for it as they waited
 *	at boot.
 *
 *	32 bytes from the hardware that are one 32-bit word eight times,
 *	or that repeat the last 32 it gave, are not taken: an unmapped
 *	register or a stuck FIFO reads like that, and the hardware's own
 *	health tests do not see what a driver does with its words.
 *
 *	ChaCha20 is checked against RFC 8439's test vector before its
 *	first use. A kernel built wrong (an alignment fault, a compiler
 *	that took liberties) would otherwise make a stream that looks
 *	random and is not the one specified; this one panics instead.
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
 * to the QEMU machines that have no generator. The counter then keys
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
	Seedbytes	= 32,
	Reseedms	= 1000,
	Reseedbytes	= 1<<20,
	Retryms		= 100,		/* a dry generator is asked again no sooner */
	Stalems		= 10*60*1000,	/* the longest the old key serves while the generator is dry */
	Chunk		= 64*1024,	/* a longer request rekeys between pieces */
	Tellms		= 5000,
};

static struct
{
	QLock	q;
	ChaChastate cs;
	int	seeded;		/* 0 never, 1 by the hardware, 2 by the counter (insecurerandom) */
	vlong	seedms;		/* when last reseeded */
	int	dry;		/* the hardware had no reseed to give at triedms */
	vlong	triedms;
	uvlong	since;		/* bytes given since the last reseed */
	uchar	last[SHA256dlen];	/* the hash of the last seed, to see one repeated */
	int	katdone;
	ulong	reseeds;
	ulong	refused;	/* seeds not taken */
} drbg;

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
 * RFC 8439 2.3.2: the block function, key 00..1f, nonce
 * 00:00:00:09:00:00:00:4a:00:00:00:00, block count 1.
 */
static void
chachakat(void)
{
	static uchar want[64] = {
		0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
		0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03, 0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
		0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09, 0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
		0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9, 0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e,
	};
	static uchar nonce[12] = { 0, 0, 0, 0x09, 0, 0, 0, 0x4a, 0, 0, 0, 0 };
	uchar key[32], out[64+3], *o;
	ChaChastate cs;
	int i;

	for(i = 0; i < 32; i++)
		key[i] = i;
	setupChaChastate(&cs, key, 32, nonce, 12, 20);
	chacha_setctr(&cs, 1);
	o = out + 3;		/* not word-aligned, as a reader's buffer need not be */
	memset(o, 0, 64);
	chacha_encrypt(o, 64, &cs);
	if(memcmp(o, want, 64) != 0)
		panic("random: ChaCha20 does not give RFC 8439's test vector; this kernel cannot make keys");
}

/*
 * qlocked: the next key from the current one, after which the state
 * that made it is gone (fast key erasure); and in *c, the stream that
 * follows those 32 bytes, so no output is ever also a key.
 */
static void
rekey(ChaChastate *c)
{
	*c = drbg.cs;
	chacha_encrypt((uchar*)&drbg.cs.state[4], 32, c);
	if(++drbg.cs.state[13] == 0)
		if(++drbg.cs.state[14] == 0)
			++drbg.cs.state[15];
}

/* qlocked: n bytes */
static void
fill(uchar *p, int n)
{
	ChaChastate c;
	int m;

	while(n > 0){
		m = n;
		if(m > Chunk)
			m = Chunk;
		rekey(&c);
		memset(p, 0, m);
		chacha_encrypt(p, m, &c);
		drbg.since += m;
		p += m;
		n -= m;
	}
	wipe(&c, sizeof c);
}

/*
 * qlocked: Seedbytes from the hardware, mixed into the key. 1 when
 * they were; 0 when the generator had none to give, or gave what is
 * refused above; -1 when this machine has none.
 */
static int
reseed(void)
{
	static uchar nonce[12];
	uchar buf[2*Seedbytes], h[SHA256dlen];
	ChaChastate c;
	u32int *w;
	int i, got, r, weak;

	weak = 0;
	for(got = 0; got < Seedbytes; got += r){
		r = hwrandom(buf + Seedbytes + got, Seedbytes - got);
		if(r < 0 && insecureok()){
			weakrandom(buf + Seedbytes + got, Seedbytes - got);
			weak = 1;
			break;
		}
		if(r <= 0){
			wipe(buf, sizeof buf);
			return r;
		}
	}

	if(!weak){
		w = (u32int*)(buf + Seedbytes);
		for(i = 1; i < Seedbytes/4; i++)
			if(w[i] != w[0])
				break;
		sha256(buf + Seedbytes, Seedbytes, h, nil);
		if(i == Seedbytes/4 || memcmp(h, drbg.last, sizeof h) == 0){
			if(drbg.refused++ % 100 == 0)
				print("random: the hardware generator gave %s; not used (%lud so far)\n",
					i == Seedbytes/4 ? "one word eight times" : "the same 32 bytes twice",
					drbg.refused);
			wipe(buf, sizeof buf);
			wipe(h, sizeof h);
			return 0;
		}
		memmove(drbg.last, h, sizeof h);
	}

	/* key' = SHA-256(32 bytes of the current stream, or zeros at first || the seed) */
	memset(buf, 0, Seedbytes);
	if(drbg.seeded){
		rekey(&c);
		chacha_encrypt(buf, Seedbytes, &c);
		wipe(&c, sizeof c);
	}
	sha256(buf, sizeof buf, h, nil);
	setupChaChastate(&drbg.cs, h, sizeof h, nonce, sizeof nonce, 20);
	wipe(buf, sizeof buf);
	wipe(h, sizeof h);

	if(drbg.seeded == 0)
		drbg.seeded = weak ? 2 : 1;
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
		chachakat();
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
 * Nothing to start: the first request checks ChaCha20 and seeds. But a
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
