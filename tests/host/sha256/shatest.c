/*
 * libsec's SHA-256, sha256block.c's C and sha256arm64.c's ARMv8
 * instructions, against FIPS 180-4's examples and against each other.
 * Built by tests/host/armcrypto_test.sh.
 */
#include "os.h"
#include <libsec.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int sha256arm64ok(void);
void sha256arm64use(int);

static int failed;

static void
hexof(uchar *d, char *s)
{
	int i;

	for(i = 0; i < SHA256dlen; i++)
		sprintf(s + 2*i, "%02x", d[i]);
}

static void
vectors(const char *path)
{
	static struct { const char *m; long rep; const char *h; } v[] = {
		{"abc", 1, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		{"", 1, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		{"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 1, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
		{"a", 1000000, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
	};
	uchar d[SHA256dlen];
	char got[2*SHA256dlen+1];
	DigestState *s;
	long r;
	int i;

	for(i = 0; i < nelem(v); i++){
		if(v[i].rep == 1)
			sha256((uchar*)v[i].m, strlen(v[i].m), d, nil);
		else{
			s = nil;
			for(r = 0; r < v[i].rep; r++)
				s = sha256((uchar*)v[i].m, strlen(v[i].m), nil, s);
			sha256(nil, 0, d, s);
		}
		hexof(d, got);
		if(strcmp(got, v[i].h) != 0){
			printf("FAIL: %s: FIPS 180-4 example %d: %s\n", path, i, got);
			failed = 1;
		}
	}
}

/* random messages fed in random pieces, both paths, the same digests */
static void
cross(void)
{
	static uchar m[5000];
	uchar d0[SHA256dlen], d1[SHA256dlen];
	DigestState *s;
	int t, n, o, k, pass;

	srand(1);
	for(t = 0; t < 3000; t++){
		n = rand() % sizeof m;
		for(o = 0; o < n; o++)
			m[o] = rand();
		for(pass = 0; pass < 2; pass++){
			sha256arm64use(pass);
			s = nil;
			srand(t);
			for(o = 0; o < n; o += k){
				k = rand() % 300;
				if(k > n - o)
					k = n - o;
				s = sha256(m + o, k, nil, s);
			}
			sha256(nil, 0, pass ? d1 : d0, s);
		}
		srand(t + 100000);
		if(memcmp(d0, d1, sizeof d0) != 0){
			printf("FAIL: the two paths disagree on a message of %d bytes\n", n);
			failed = 1;
			return;
		}
	}
	printf("PASS: the two paths agree on 3000 random messages in random pieces\n");
}

static double
speed(void)
{
	static uchar m[1<<20];
	uchar d[SHA256dlen];
	struct timespec a, b;
	int i;

	clock_gettime(CLOCK_MONOTONIC, &a);
	for(i = 0; i < 64; i++)
		sha256(m, sizeof m, d, nil);
	clock_gettime(CLOCK_MONOTONIC, &b);
	return 64.0 / ((b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9);
}

int
main(void)
{
	sha256arm64use(0);
	vectors("C");
	printf("C: %.0f MB/s\n", speed());
	sha256arm64use(1);
	if(sha256arm64ok()){
		vectors("ARMv8");
		printf("ARMv8: %.0f MB/s\n", speed());
		cross();
	}else
		printf("SKIP: no SHA-256 instructions here\n");
	if(!failed)
		printf("PASS: FIPS 180-4 examples on every path\n");
	return failed;
}
