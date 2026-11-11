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

enum { None, Dry, Good, Stuck, Repeat, Runs, Biased };

Mach fakemach;
static Proc proc0;
Proc *up = &proc0;

static int hwmode;
static int hwmax = 1<<30;		/* most bytes one call gives */
static u64int hwstate = 0x0123456789ABCDEFULL;
static long hwbytes;			/* given, all told */
static long hwcalls;
static uchar hwlast[80];		/* the last 80 given */
static uchar repeatblk[64];
static int repeatpos;
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
			p[i] = repeatblk[repeatpos++ % 64];
			break;
		case Runs:			/* each byte eight times */
			if((hwbytes & 7) == 0)
				hwbyte();
			p[i] = hwstate >> 24;
			break;
		case Biased:			/* a quarter of the bytes 0 */
			p[i] = (hwbytes & 3) == 0 ? 0 : hwbyte();
			break;
		}
		memmove(hwlast, hwlast+1, sizeof hwlast - 1);
		hwlast[sizeof hwlast - 1] = p[i];
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
 * HMAC_DRBG with SHA-512, written out again from NIST SP 800-90A Rev. 1,
 * 10.1.2, over libsec's hmac_sha512, so the test does not read the code
 * it tests. It is checked against NIST's vectors (the "vectors" case)
 * before the kernel is checked against it.
 */
typedef struct Model Model;
struct Model
{
	uchar k[64];
	uchar v[64];
};

static char personal[] = "InferNode os/port/random.c HMAC_DRBG SHA-512";

static void
mupdate(Model *m, uchar *data, int n)
{
	uchar buf[64+1+256];
	int round;

	for(round = 0; round < 2; round++){
		if(round == 1 && n == 0)
			break;
		memmove(buf, m->v, 64);
		buf[64] = round;
		memmove(buf+65, data, n);
		hmac_sha512(buf, 65+n, m->k, 64, m->k, nil);
		hmac_sha512(m->v, 64, m->k, 64, m->v, nil);
	}
}

static void
minstantiate(Model *m, uchar *e, int ne, uchar *nonce, int nn, uchar *ps, int nps)
{
	uchar buf[256];

	memset(m->k, 0, 64);
	memset(m->v, 1, 64);
	memmove(buf, e, ne);
	memmove(buf+ne, nonce, nn);
	memmove(buf+ne+nn, ps, nps);
	mupdate(m, buf, ne+nn+nps);
}

/* one Generate of n bytes */
static void
mgenerate(Model *m, uchar *out, int n)
{
	int k;

	for(; n > 0; n -= k, out += k){
		hmac_sha512(m->v, 64, m->k, 64, m->v, nil);
		k = n < 64 ? n : 64;
		memmove(out, m->v, k);
	}
	mupdate(m, nil, 0);
}

/* a request of n bytes, a Generate for each 64K */
static void
mfill(Model *m, uchar *out, int n)
{
	int k;

	for(; n > 0; n -= k, out += k){
		k = n < 65536 ? n : 65536;
		mgenerate(m, out, k);
	}
}

/* the first seed: 64 bytes of entropy and 16 of nonce, as the hardware gave them */
static void
mfirst(Model *m, uchar *hw80)
{
	minstantiate(m, hw80, 64, hw80+64, 16, (uchar*)personal, strlen(personal));
}

static int
unhex(char *s, uchar *b)
{
	int n;
	unsigned x;

	if(strcmp(s, "-") == 0)
		return 0;
	for(n = 0; s[2*n] && s[2*n+1]; n++){
		sscanf(s + 2*n, "%2x", &x);
		b[n] = x;
	}
	return n;
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
vectors(void)
{
	FILE *f;
	char line[8192], kind[32], e[256], n[256], ps[256], rs[256], ret[1024];
	uchar be[128], bn[128], bps[128], brs[128], want[512], got[256];
	int count, ne, nn, nps, nrs;
	Model m;

	f = fopen(getenv("KERNRANDOM_VECTORS"), "r");
	check(f != nil, "vectors: the file of NIST's vectors opens");
	if(f == nil)
		return;
	count = 0;
	while(fgets(line, sizeof line, f) != nil){
		if(line[0] == '#' || line[0] == '\n')
			continue;
		if(sscanf(line, "%31s %255s %255s %255s %255s %1023s", kind, e, n, ps, rs, ret) != 6){
			check(0, "vectors: a line of six fields");
			continue;
		}
		ne = unhex(e, be);
		nn = unhex(n, bn);
		nps = unhex(ps, bps);
		nrs = unhex(rs, brs);
		check(unhex(ret, want) == 256, "vectors: 2048 bits returned");
		minstantiate(&m, be, ne, bn, nn, bps, nps);
		if(nrs > 0)
			mupdate(&m, brs, nrs);
		mgenerate(&m, got, 256);
		mgenerate(&m, got, 256);
		if(memcmp(got, want, 256) != 0){
			fprintf(stderr, "vector %d (%s) differs\n", count, kind);
			check(0, "vectors: the model gives NIST's ReturnedBits");
		}
		count++;
	}
	fclose(f);
	check(count == 60, "vectors: all 60 read");
}

static void
construction(void)
{
	Model m;
	uchar seed[80], got[300], want[300];
	long before;

	hwmode = Good;
	hwmax = 5;		/* short reads, as a generator gives */
	genrandom(got, 100);
	check(hwbytes == 80, "the first request takes exactly 80 bytes from the hardware (64 entropy, 16 nonce)");
	memmove(seed, hwlast, 80);
	mfirst(&m, seed);
	mfill(&m, want, 100);
	check(memcmp(got, want, 100) == 0, "output is HMAC_DRBG instantiated from the 80 bytes and the personalization string");
	check(memmem(got, 100, seed, 4) == nil, "no hardware bytes appear in the output");

	before = hwbytes;
	fakemach.ticks += 999;
	genrandom(got+1, 299);	/* unaligned */
	mfill(&m, want+1, 299);
	check(hwbytes == before, "a request within a second of the reseed takes nothing from the hardware");
	check(memcmp(got+1, want+1, 299) == 0, "the next request is the next Generate");

	fakemach.ticks += 1;
	genrandom(got, 64);
	check(hwbytes == before + 64, "a request a second after the reseed reseeds with 64 bytes");
	mupdate(&m, hwlast + 16, 64);
	mfill(&m, want, 64);
	check(memcmp(got, want, 64) == 0, "the reseed is SP 800-90A's Reseed with the 64 bytes");
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
	check(hwbytes == before + 64, "a request after a megabyte reseeds");
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
	check(logged("one word over and over"), "a stuck generator: the console says so");
}

static void
repeated(void)
{
	uchar a[32], b[32];
	long before;

	hwmode = Good;
	genrandom(a, 32);
	memmove(repeatblk, hwlast, 64);	/* the first seed's entropy, without its nonce */
	hwmode = Repeat;
	before = hwbytes;
	fakemach.ticks += 1000;
	genrandom(b, 32);
	check(hwbytes == before + 64, "a reseed was tried");
	check(logged("the same seed twice"), "a seed that repeats the last is refused, and said so");
	check(memcmp(a, b, 32) != 0, "the old state goes on serving after a refused seed");
}

/* SP 800-90B 4.4.1: six bytes alike in a row fail */
static void
runs(void)
{
	uchar buf[32];

	hwmode = Runs;
	memset(buf, 0x5A, sizeof buf);
	sleeplimit = 10;
	if(setjmp(escape) == 0){
		genrandom(buf, 32);
		check(0, "runs of one byte seed the generator");
	}
	check(untouched(buf, 32), "runs of one byte: nothing written");
	check(logged("health tests"), "runs of one byte: the console says the health tests failed");
}

/* SP 800-90B 4.4.2: one byte value 62 times in 512 fails, across reseeds */
static void
biased(void)
{
	uchar a[32], b[32];
	int i;

	hwmode = Biased;
	genrandom(a, 32);
	check(!logged("health tests"), "a biased source: the first 80 bytes pass");
	for(i = 0; i < 8; i++){
		fakemach.ticks += 1000;
		genrandom(b, 32);
	}
	check(logged("health tests"), "a biased source: refused within 600 bytes");
	check(memcmp(a, b, 32) != 0, "a biased source: the old state goes on serving");
}

/* the Biased source passes the test that catches it when it is not biased */
static void
unbiased(void)
{
	uchar b[32];
	int i;

	hwmode = Good;
	for(i = 0; i < 200; i++){
		fakemach.ticks += 1000;
		genrandom(b, 32);
	}
	check(!logged("not used"), "a good source: 200 reseeds, none refused");
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
	{ "NIST's HMAC_DRBG vectors (the model)", vectors },
	{ "construction", construction },
	{ "long request", bigrequest },
	{ "dry after seeding", dryafterseed },
	{ "stuck generator", stuck },
	{ "repeated seed", repeated },
	{ "repetition count (SP 800-90B 4.4.1)", runs },
	{ "adaptive proportion (SP 800-90B 4.4.2)", biased },
	{ "a good source is not refused", unbiased },
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
