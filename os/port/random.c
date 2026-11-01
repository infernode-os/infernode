/*
 * Imported from upstream Inferno os/port/random.c.
 *
 * DIVERGENCE FROM UPSTREAM: the embedded QLock in the random-buffer
 * struct is named. See os/bcm2837/README.md. The pool is fed from the
 * board's hardware generator, not a spin loop (below). And this file,
 * not the board's, now holds genrandom, prng and prngtry -- the names
 * libsec's key generators call -- so the rule they keep is written
 * once:
 *
 *	A SECRET IS MADE ONLY FROM THE HARDWARE GENERATOR.
 *
 * The board's hwrandom(p, n) returns how many real bytes it had (it
 * may be short, and it must not spin), 0 when the generator is dry
 * for now, and -1 when this machine has no generator at all --
 * hwrandom(nil, 0) asks only that. It never makes bytes up. Every board once did, when it had no generator: a
 * counter stirred with the time, handed to the key generators after
 * one warning on the console. That suited QEMU, which has no RNG200
 * and no PolarFire nonce service, and it was wrong on a board, where
 * the same thing means a driver or a map at fault. On a Pi 5 it could
 * only ever be that, since no emulator models one.
 *
 * So with no generator a key is not made: genrandom waits, saying so
 * every few seconds, and #c/random's readers wait with it. The machine
 * still boots and still talks to the network, since nrand -- port
 * numbers and TCP sequence numbers, not secrets, and an LCG over the
 * clock since upstream -- never waits (devcons.c's seedrand).
 *
 * The counter is still here for an emulator that has nothing better.
 * It is used only when the boot command line holds the word
 * "insecurerandom", which says in so many words what the boot is, and
 * which tests/host/baremetal_test.sh passes to the QEMU machines that
 * have no generator. It is labelled on the console, in capitals, when
 * it is first used.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

static struct
{
	QLock	q;
	Rendez	producer;
	Rendez	consumer;
	ulong	randomcount;
	uchar	buf[1024];
	uchar	*ep;
	uchar	*rp;
	uchar	*wp;
	uchar	next;
	uchar	bits;
	uchar	wakeme;
	uchar	filled;
	int	target;
	int	kprocstarted;
	ulong	randn;
} rb;

static int
rbnotfull(void*)
{
	int i;

	i = rb.wp - rb.rp;
	if(i < 0)
		i += sizeof(rb.buf);
	return i < rb.target;
}

static int
rbnotempty(void*)
{
	return rb.wp != rb.rp;
}

static int	insecureok(void);
static int	weakrandom(uchar*, int);

/*
 * The producer, rewritten around the hardware generator.
 *
 * Upstream's producer spins a counter to 100000 and lets the clock
 * interrupt sample the jitter between them -- the right design for
 * hardware with no RNG, and a measured 18% of this machine's busy CPU
 * for two bits of doubtful entropy every 13ms. Every port in this
 * tree already provides hwrandom() (randominit() below refuses to
 * work without it), so the producer's job reduces to: when the pool
 * has room, move bytes from the generator into it, and otherwise cost
 * nothing at all.
 *
 * randomclock() still runs off the clock link and still no-ops --
 * randomcount never advances now, so its first test fails -- which
 * keeps this file one diff away from a port that genuinely has no
 * generator and needs the jitter loop back.
 *
 * With no generator, and no "insecurerandom", the pool is never
 * filled and its readers wait; while one does, this says why every
 * five seconds, since a read that never returns would otherwise be
 * taken for anything but this.
 */
static void
randomproc(void*)
{
	uchar tmp[64], *p;
	int i, got, dry;

	setpri(PriBackground);

	dry = 0;
	for(;;) {
		sleep(&rb.producer, rbnotfull, 0);
		while(rbnotfull(0)){
			got = hwrandom(tmp, sizeof tmp);
			if(got < 0 && insecureok())
				got = weakrandom(tmp, sizeof tmp);
			if(got <= 0){
				/* generator dry, or none; do not turn into a spin */
				if(rb.wakeme && ++dry % 50 == 0)
					print("random: %s; a reader of #c/random has waited %d seconds\n",
						got < 0 ? "there is NO ENTROPY SOURCE on this machine, so it will go on waiting"
							: "the hardware generator has produced nothing",
						dry/10);
				tsleep(&up->sleep, return0, 0, 100);
				continue;
			}
			dry = 0;
			for(i = 0; i < got && rbnotfull(0); i++){
				*rb.wp ^= tmp[i];
				p = rb.wp + 1;
				if(p == rb.ep)
					p = rb.buf;
				rb.wp = p;
			}
			if(rb.wakeme)
				wakeup(&rb.consumer);
		}
		memset(tmp, 0, sizeof tmp);
	}
}

/*
 *  produce random bits in a circular buffer
 */
static void
randomclock(void)
{
	uchar *p;

	if(rb.randomcount == 0)
		return;

	if(!rbnotfull(0)) {
		rb.filled = 1;
		return;
	}

	rb.bits = (rb.bits<<2) ^ (rb.randomcount&3);
	rb.randomcount = 0;

	rb.next += 2;
	if(rb.next != 8)
		return;

	rb.next = 0;
	*rb.wp ^= rb.bits ^ *rb.rp;
	p = rb.wp+1;
	if(p == rb.ep)
		p = rb.buf;
	rb.wp = p;

	if(rb.wakeme)
		wakeup(&rb.consumer);
}

void
randominit(void)
{
	/* Frequency close but not equal to HZ */
	addclock0link(randomclock, 13);
	rb.target = 16;
	rb.ep = rb.buf + sizeof(rb.buf);
	rb.rp = rb.wp = rb.buf;

	/*
	 * Prime the pool from the hardware generator.
	 *
	 * Without this the FIRST caller to want randomness sleeps in
	 * randomread() until the clock-jitter producer has stirred enough
	 * bits in -- and if that producer is not running, or is not
	 * getting scheduled, it sleeps forever. That is not a theoretical
	 * risk: it hung this kernel the first time anything opened a
	 * network conversation, because setlport() calls nrand() to pick a
	 * port and nrand() seeds itself from here.
	 *
	 * Priming removes the dependency on the producer ever having run,
	 * which is what makes the failure impossible rather than unlikely.
	 * The jitter producer still runs and still stirs the pool; it is
	 * simply no longer the only source.
	 */
	{
		int got;

		/*
		 * One byte short of the buffer, deliberately. rb is a
		 * circular buffer in which wp == rp means EMPTY, so filling
		 * it completely wraps wp back onto rp and the pool reads as
		 * empty again -- priming it perfectly and achieving nothing.
		 */
		got = hwrandom(rb.buf, sizeof(rb.buf) - 1);
		if(got < 0 && insecureok())
			got = weakrandom(rb.buf, sizeof(rb.buf) - 1);
		if(got > 0)
			rb.wp = rb.buf + got;
	}
}

/*
 *  consume random bytes from a circular buffer
 */
ulong
randomread(void *xp, ulong n)
{
	int i, sofar;
	uchar *e, *p;

	p = xp;

	qlock(&rb.q);
	if(waserror()){
		qunlock(&rb.q);
		nexterror();
	}
	if(!rb.kprocstarted){
		rb.kprocstarted = 1;
		kproc("genrand", randomproc, nil, 0);
	}

	for(sofar = 0; sofar < n; sofar += i){
		i = rb.wp - rb.rp;
		if(i == 0){
			rb.wakeme = 1;
			wakeup(&rb.producer);
			sleep(&rb.consumer, rbnotempty, 0);
			rb.wakeme = 0;
			continue;
		}
		if(i < 0)
			i = rb.ep - rb.rp;
		if((i+sofar) > n)
			i = n - sofar;
		memmove(p + sofar, rb.rp, i);
		e = rb.rp + i;
		if(e == rb.ep)
			e = rb.buf;
		rb.rp = e;
	}
	if(rb.filled && rb.wp == rb.rp){
		i = 2*rb.target;
		if(i > sizeof(rb.buf) - 1)
			i = sizeof(rb.buf) - 1;
		rb.target = i;
		rb.filled = 0;
	}
	poperror();
	qunlock(&rb.q);

	wakeup(&rb.producer);

	return n;
}

/*
 * "insecurerandom", as a whole word of the boot command line. Read
 * each time rather than once: randominit can run before a board has
 * read its command line, and this is asked only when there is no
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

/*
 * Wait for the generator, without spinning where sleeping is allowed:
 * genrandom is called from processes (devcons, and libsec's key
 * generators under $Keyring), but nothing here assumes it. Returns the
 * milliseconds waited.
 */
static int
randomwait(void)
{
	if(up != nil && islo()){
		tsleep(&up->sleep, return0, 0, 100);
		return 100;
	}
	microdelay(1000);
	return 1;
}

/*
 * genrandom -- n bytes from the hardware generator, ALL of them from
 * the hardware generator, however long that takes.
 *
 * It began as "the fast, explicitly non-cryptographic source behind
 * #c/notquiterandom", and for that a short read padded with zeros was
 * a fair answer. But prng() and prngtry() are libsec's SECURE entropy
 * entry points and delegate here, and libsec's key generators -- RSA,
 * DSA, ElGamal, ECC, Ed25519, ML-KEM, ML-DSA, SLH-DSA -- call genrandom
 * by name. So the padding became a private key whose tail is zeros,
 * made without a word to anyone, whenever hwrandom() came back short
 * (#658). And it can come back short: hwrandom gives up after a
 * bounded spin, and the BCM2837's generator discards Rngwarmup words
 * after it is enabled before it offers one.
 *
 * So: wait. A key is worth waiting for, and a machine with a dead
 * generator, or none, should not be minting keys, so this fails closed
 * -- it does not return until the bytes are real, and it says so on
 * the console every five seconds while it waits, because a boot that
 * hangs silently here would be read as anything but this.
 */
void
genrandom(uchar *p, int n)
{
	int got, r, waited, last;

	waited = 0;
	last = 0;
	for(got = 0; got < n; ){
		r = hwrandom(p + got, n - got);
		if(r > 0){
			got += r;
			continue;
		}
		if(r < 0 && insecureok()){
			weakrandom(p + got, n - got);
			return;
		}
		waited += randomwait();
		if(waited - last >= 5000){
			last = waited;
			if(r < 0)
				print("random: there is NO ENTROPY SOURCE on this machine; %d bytes of key material "
					"have waited %d seconds and will not be made from anything else\n",
					n - got, waited/1000);
			else
				print("random: the hardware generator has produced nothing for %d seconds; still waiting for %d bytes\n",
					waited/1000, n - got);
		}
	}
}

/*
 * libsec's entropy entry points, which its host build (prng.c) fills
 * from getentropy/urandom. On bare metal the hardware generator is the
 * secure source, so both delegate to genrandom.
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
