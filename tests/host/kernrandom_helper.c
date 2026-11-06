#define _GNU_SOURCE
/*
 * The native kernel's random-number generator (os/port/random.c), run
 * on the host against a generator, a clock and a sleep this file
 * drives. Each case runs in a child of its own, so each starts from a
 * kernel that has made nothing yet. See kernrandom_test.sh.
 */
#include "kernrandom_shim.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <setjmp.h>
#include <unistd.h>
#include <sys/wait.h>

/* ---- the kernel, as random.c sees it ---- */

enum { None, Dry, Good, Stuck, Repeat };

Mach fakemach;
static Proc proc0;
Proc *up = &proc0;

static int hwmode;
static int hwmax = 1<<30;		/* most bytes one call gives */
static u64int hwstate = 0x0123456789ABCDEFULL;
static long hwbytes;			/* given, all told */
static long hwcalls;
static uchar hwlast[32];		/* the last 32 given */
static uchar repeatblk[32];
static char *cmdline = "";

static char logbuf[1<<16];
static int nlog;

static int sleeps, sleeplimit = 1<<30;
static int switchat = -1, switchto;	/* at that many sleeps, hwmode becomes switchto */
static jmp_buf escape;
static int releases, acquires, badrelease;

void qlock(QLock *q) { (void)q; }
void qunlock(QLock *q) { (void)q; }
void ilock(Lock *l) { (void)l; }
void iunlock(Lock *l) { (void)l; }
int islo(void) { return 1; }
void microdelay(int n) { (void)n; }
int return0(void *a) { (void)a; return 0; }
uvlong fastticks(uvlong *h) { (void)h; return fakemach.ticks * 1000 + 7; }
char *boardcmdline(void) { return cmdline; }

void
release(void)
{
	if(up->type != Interp || up->iprog != nil)
		badrelease++;
	up->iprog = (void*)1;
	releases++;
}

void
acquire(void)
{
	up->iprog = nil;
	acquires++;
}

int
print(char *fmt, ...)
{
	va_list a;
	int n;

	va_start(a, fmt);
	n = vsnprintf(logbuf + nlog, sizeof logbuf - nlog, fmt, a);
	va_end(a);
	if(n > 0 && nlog + n < (int)sizeof logbuf)
		nlog += n;
	return n;
}

void
panic(char *fmt, ...)
{
	va_list a;

	va_start(a, fmt);
	fprintf(stderr, "panic: ");
	vfprintf(stderr, fmt, a);
	fprintf(stderr, "\n");
	va_end(a);
	exit(3);
}

void
tsleep(Rendez *r, int (*f)(void*), void *a, ulong ms)
{
	(void)r; (void)f; (void)a;
	fakemach.ticks += ms;
	sleeps++;
	if(sleeps == switchat)
		hwmode = switchto;
	if(sleeps >= sleeplimit)
		longjmp(escape, 1);
}

static uchar
hwbyte(void)
{
	hwstate ^= hwstate << 13;
	hwstate ^= hwstate >> 7;
	hwstate ^= hwstate << 17;
	return hwstate >> 24;
}

int
hwrandom(uchar *p, int n)
{
	int i;

	if(hwmode == None)
		return -1;
	if(p == nil || n == 0)
		return 0;
	hwcalls++;
	if(hwmode == Dry)
		return 0;
	if(n > hwmax)
		n = hwmax;
	for(i = 0; i < n; i++){
		switch(hwmode){
		case Good:
			p[i] = hwbyte();
			break;
		case Stuck:
			p[i] = 0x12 + (hwbytes & 3);	/* one word, over and over */
			break;
		case Repeat:
			p[i] = repeatblk[hwbytes % 32];
			break;
		}
		memmove(hwlast, hwlast+1, 31);
		hwlast[31] = p[i];
		hwbytes++;
	}
	return n;
}

/* ---- checking ---- */

static int failed;

static void
check(int ok, char *what)
{
	if(!ok){
		fprintf(stderr, "FAIL: %s\n", what);
		failed = 1;
	}
}

static int
logged(char *s)
{
	logbuf[nlog] = 0;
	return strstr(logbuf, s) != nil;
}

/* nonzero if p..n stays as it was set (all 0x5A) */
static int
untouched(uchar *p, int n)
{
	int i;

	for(i = 0; i < n; i++)
		if(p[i] != 0x5A)
			return 0;
	return 1;
}

/*
 * The construction, written out again from RFC 8439 and the comment
 * at the top of random.c, so the test does not read the code it tests.
 */
typedef struct Model Model;
struct Model
{
	uchar key[32];
	u32int nonce[3];
};

static void
modelstate(Model *m, ChaChastate *c)
{
	static uchar zero[12];

	setupChaChastate(c, m->key, 32, zero, 12, 20);
	c->state[13] = m->nonce[0];
	c->state[14] = m->nonce[1];
	c->state[15] = m->nonce[2];
}

/* one request of n bytes (n <= 64K): rekey, then output */
static void
modelfill(Model *m, uchar *out, int n)
{
	ChaChastate c;
	uchar ks[32];
	int i;

	modelstate(m, &c);
	memset(ks, 0, 32);
	chacha_encrypt(ks, 32, &c);
	for(i = 0; i < 32; i++)
		m->key[i] ^= ks[i];
	if(++m->nonce[0] == 0)
		if(++m->nonce[1] == 0)
			++m->nonce[2];
	memset(out, 0, n);
	chacha_encrypt(out, n, &c);
}

/* a reseed: SHA-256(32 bytes of stream, or zeros the first time || seed) */
static void
modelseed(Model *m, int first, uchar *seed)
{
	uchar buf[64];

	memset(buf, 0, 32);
	if(!first)
		modelfill(m, buf, 32);
	memmove(buf+32, seed, 32);
	sha256(buf, 64, m->key, nil);
	memset(m->nonce, 0, sizeof m->nonce);
}

/* ---- the cases ---- */

static void
nogenerator(void)
{
	uchar buf[32];

	hwmode = None;
	up->type = Interp;
	memset(buf, 0x5A, sizeof buf);
	sleeplimit = 60;
	if(setjmp(escape) == 0){
		genrandom(buf, sizeof buf);
		check(0, "no generator: genrandom returned");
	}
	check(untouched(buf, sizeof buf), "no generator: nothing written");
	check(logged("NO ENTROPY SOURCE on this machine; 32 bytes of key material have waited 5 seconds"),
		"no generator: the console says why a key waits");
	check(releases >= 59 && acquires == releases - 1 && badrelease == 0,
		"no generator: the VM is let go for every wait and taken back after it");
	check(prngtry(buf, 4) == -1, "no generator: prngtry says -1 at once");

	sleeps = 0;
	if(setjmp(escape) == 0){
		up->iprog = nil;
		randomread(buf, 8);
		check(0, "no generator: #c/random returned");
	}
	check(logged("a reader of #c/random has waited 5 seconds"), "no generator: the console says why #c/random waits");
}

static void
notvm(void)
{
	uchar buf[8];

	hwmode = None;
	up->type = 0;
	sleeplimit = 3;
	if(setjmp(escape) == 0)
		genrandom(buf, sizeof buf);
	check(releases == 0 && acquires == 0, "a process without the VM waits without release/acquire");
}

static void
insecure(void)
{
	uchar buf[32];

	hwmode = None;
	cmdline = "console=0 insecurerandomx";
	sleeplimit = 5;
	if(setjmp(escape) == 0){
		genrandom(buf, sizeof buf);
		check(0, "insecurerandomx counts as insecurerandom");
	}
	cmdline = "console=0 insecurerandom quiet";
	sleeps = 0;
	if(setjmp(escape) == 0)
		genrandom(buf, sizeof buf);
	else
		check(0, "insecurerandom: genrandom still waits");
	check(logged("Keys made on it are PREDICTABLE"), "insecurerandom: the console says what it is");
	check(prngtry(buf, 4) == 0, "insecurerandom: prngtry answers");
}

static void
construction(void)
{
	Model m;
	uchar seed[32], got[300], want[300];
	long before;

	hwmode = Good;
	hwmax = 5;		/* short reads, as a generator gives */
	genrandom(got, 100);
	check(hwbytes == 32, "the first request takes exactly 32 bytes from the hardware");
	memmove(seed, hwlast, 32);
	memset(&m, 0, sizeof m);
	modelseed(&m, 1, seed);
	modelfill(&m, want, 100);
	check(memcmp(got, want, 100) == 0, "output is ChaCha20 keyed by SHA-256(0^32 || seed), after the 32 bytes that rekey it");
	check(memmem(got, 100, seed, 4) == nil, "no hardware bytes appear in the output");

	before = hwbytes;
	fakemach.ticks += 999;
	genrandom(got+1, 299);	/* unaligned */
	modelfill(&m, want+1, 299);
	check(hwbytes == before, "a request within a second of the reseed takes nothing from the hardware");
	check(memcmp(got+1, want+1, 299) == 0, "the next request continues from the erased key");

	fakemach.ticks += 1;
	genrandom(got, 64);
	check(hwbytes == before + 32, "a request a second after the reseed reseeds");
	memmove(seed, hwlast, 32);
	modelseed(&m, 0, seed);
	modelfill(&m, want, 64);
	check(memcmp(got, want, 64) == 0, "the reseed is SHA-256(32 bytes of the old stream || new seed)");
}

static void
bigrequest(void)
{
	enum { N = (1<<20) + 64 };
	uchar *b;
	long before;
	int i, j, same;

	hwmode = Good;
	b = malloc(N);
	genrandom(b, 16);
	before = hwbytes;
	genrandom(b, N);
	check(hwbytes == before, "a long request is served without the hardware");
	same = 0;
	for(i = 0; i < N/65536; i++)
		for(j = 0; j < i; j++)
			if(memcmp(b + 65536*i, b + 65536*j, 64) == 0)
				same++;
	check(same == 0, "each 64K of a long request starts from a key of its own");
	genrandom(b, 16);
	check(hwbytes == before + 32, "a request after a megabyte reseeds");
	free(b);
}

static void
dryafterseed(void)
{
	uchar a[32], b[32];
	long calls;

	hwmode = Good;
	genrandom(a, 32);
	hwmode = Dry;
	fakemach.ticks += 2000;
	sleeplimit = 1;
	if(setjmp(escape) == 0)
		genrandom(b, 32);
	else
		check(0, "a dry generator stops the old key at once");
	check(memcmp(a, b, 32) != 0, "the old key's output moves on");
	calls = hwcalls;
	genrandom(b, 32);
	check(hwcalls == calls, "a dry generator is not asked again within 100 ms");
	fakemach.ticks += 100;
	genrandom(b, 32);
	check(hwcalls == calls + 1, "a dry generator is asked again after 100 ms");

	fakemach.ticks += 10*60*1000 - 2200;
	genrandom(b, 32);			/* still within ten minutes of the seed */
	fakemach.ticks += 200;
	sleeplimit = 60;
	switchat = 55;
	switchto = Good;
	if(setjmp(escape) == 0)
		genrandom(b, 32);
	else
		check(0, "the generator's return was not noticed");
	check(sleeps == 55, "after ten minutes dry, the old key serves no more until the generator is back");
	check(logged("the hardware generator has produced nothing for 5 seconds; still waiting for 32 bytes"),
		"after ten minutes dry, the console says why a key waits");
}

static void
stuck(void)
{
	uchar buf[32];

	hwmode = Stuck;
	memset(buf, 0x5A, sizeof buf);
	sleeplimit = 10;
	if(setjmp(escape) == 0){
		genrandom(buf, 32);
		check(0, "a stuck generator keys the generator");
	}
	check(untouched(buf, 32), "a stuck generator: nothing written");
	check(logged("one word eight times"), "a stuck generator: the console says so");
}

static void
repeated(void)
{
	uchar a[32], b[32];
	long before;

	hwmode = Good;
	genrandom(a, 32);
	memmove(repeatblk, hwlast, 32);
	hwmode = Repeat;
	before = hwbytes;
	fakemach.ticks += 1000;
	genrandom(b, 32);
	check(hwbytes == before + 32, "a reseed was tried");
	check(logged("the same 32 bytes twice"), "a seed that repeats the last is refused, and said so");
	check(memcmp(a, b, 32) != 0, "the old key goes on serving after a refused seed");
}

static void
distinct(void)
{
	enum { N = 4096 };
	uchar *b;
	int i, j, same;

	hwmode = Good;
	b = malloc(N*16);
	for(i = 0; i < N; i++)
		genrandom(b + 16*i, 16);
	same = 0;
	for(i = 0; i < N; i++)
		for(j = 0; j < i; j++)
			if(memcmp(b + 16*i, b + 16*j, 16) == 0)
				same++;
	check(same == 0, "4096 requests, no two alike");
	free(b);
}

static struct {
	char *name;
	void (*f)(void);
} cases[] = {
	{ "no generator", nogenerator },
	{ "a process without the VM", notvm },
	{ "insecurerandom", insecure },
	{ "construction", construction },
	{ "long request", bigrequest },
	{ "dry after seeding", dryafterseed },
	{ "stuck generator", stuck },
	{ "repeated seed", repeated },
	{ "distinct requests", distinct },
};

int
main(void)
{
	int i, st, bad;
	pid_t pid;

	bad = 0;
	for(i = 0; i < (int)(sizeof cases/sizeof cases[0]); i++){
		fflush(stdout);
		pid = fork();
		if(pid == 0){
			up->type = Interp;
			cases[i].f();
			if(failed){
				logbuf[nlog] = 0;
				fprintf(stderr, "console:\n%s\n", logbuf);
			}
			exit(failed);
		}
		waitpid(pid, &st, 0);
		if(!WIFEXITED(st) || WEXITSTATUS(st) != 0){
			printf("FAIL: kernel random: %s\n", cases[i].name);
			bad = 1;
		}else
			printf("PASS: kernel random: %s\n", cases[i].name);
	}
	return bad;
}
