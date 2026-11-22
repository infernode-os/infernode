/*
 * libsec/slhdsa*.c when an allocation fails, built by
 * tests/host/slhdsa_test.sh: the library's sources are compiled with
 * malloc renamed to slhfault_malloc, which refuses the allocations this
 * program chooses.
 *
 * Signing: with any one allocation refused, or every one from some point
 * on, the signer returns -1 and its buffer holds nothing (all zero).  It
 * used to return 0 with a signature that verified: no memory for a FORS
 * tree's leaves left the FORS part zero, the FORS public key was worked
 * out from that, and the hypertree signed it; no memory for a tree hash
 * left an authentication path of zeros and the layer above signed the
 * "root" that gave.  Either way a one-time key had signed a second
 * value, and the signature of the same message made without the failure
 * is the first.
 *
 * Verifying: a good signature is refused while an allocation fails
 * (the answer could not be worked out), never accepted by what was left
 * in a buffer.  Key generation: -1.
 */
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static long seen, failfrom = -1, failto = -1, refused;

void*
slhfault_malloc(size_t n)
{
	long i;

	i = seen++;
	if(failfrom >= 0 && i >= failfrom && i <= failto){
		refused++;
		return NULL;
	}
	return malloc(n);
}

void
genrandom(uchar *p, int n)
{
	static int fd = -1;

	if(fd < 0)
		fd = open("/dev/urandom", O_RDONLY);
	if(fd < 0 || read(fd, p, n) != n)
		abort();
}

/*
 * the signatures' hedging bytes are asked for here (libsec.h: -1 and
 * nothing when there is no generator); norng makes that the answer
 */
int	norng;

int
genrandomtry(uchar *p, int n)
{
	if(norng)
		return -1;
	genrandom(p, n);
	return 0;
}

static int fails;

static void
check(int ok, const char *what, long nth)
{
	if(!ok){
		fails++;
		fprintf(stderr, "FAIL: %s (allocation %ld refused)\n", what, nth);
	}
}

static int
allzero(const uchar *p, int n)
{
	int i;
	uchar x;

	x = 0;
	for(i = 0; i < n; i++)
		x |= p[i];
	return x == 0;
}

int
main(void)
{
	static uchar pk[SLHDSA192S_PKLEN], sk[SLHDSA192S_SKLEN];
	static uchar good[SLHDSA192S_SIGLEN], bad[SLHDSA192S_SIGLEN];
	const uchar *msg = (const uchar*)"the same message";
	long total, vtotal, nth, at[4];
	int rc, i, n, last;

	if(slhdsa192s_keygen(pk, sk) != 0){
		fprintf(stderr, "FAIL: keygen\n");
		return 1;
	}
	seen = 0;
	rc = slhdsa192s_sign(good, msg, 16, sk);
	total = seen;
	seen = 0;
	if(rc != 0 || slhdsa192s_verify(good, sizeof good, msg, 16, pk) != 1){
		fprintf(stderr, "FAIL: sign and verify with no failure\n");
		return 1;
	}
	vtotal = seen;
	if(total < 2 || vtotal < 1){
		fprintf(stderr, "FAIL: signing made %ld allocations and verifying %ld: nothing to refuse\n", total, vtotal);
		return 1;
	}

	/*
	 * one allocation refused during a second signing of the message:
	 * the first (a FORS tree's leaves), the second (the first tree
	 * hash of the hypertree), the last (the signer's own check of
	 * what it made); then every allocation from half way on
	 */
	at[0] = 0;
	at[1] = 1;
	at[2] = total - 1;
	at[3] = total/2;
	n = 0;
	for(i = 0; i < 4; i++){
		nth = at[i];
		last = i == 3;
		memset(bad, 0xA5, sizeof bad);
		seen = 0;
		refused = 0;
		failfrom = nth;
		failto = last ? total*2 : nth;
		rc = slhdsa192s_sign(bad, msg, 16, sk);
		failfrom = -1;
		check(refused > 0, "the allocation was not reached", nth);
		check(rc == -1, "sign returned success though an allocation failed", nth);
		check(allzero(bad, sizeof bad), "a failed signing left part of a signature in its buffer", nth);
		check(slhdsa192s_verify(bad, sizeof bad, msg, 16, pk) == 0, "what a failed signing left verifies", nth);
		n++;
	}

	/* verifying a good signature while an allocation fails */
	for(nth = 0; nth < vtotal; nth++){
		seen = 0;
		failfrom = failto = nth;
		rc = slhdsa192s_verify(good, sizeof good, msg, 16, pk);
		failfrom = -1;
		check(rc == 0, "verify did not refuse when it could not work the answer out", nth);
	}
	check(slhdsa192s_verify(good, sizeof good, msg, 16, pk) == 1, "the good signature no longer verifies", -1);

	/* key generation */
	memset(bad, 0, sizeof bad);
	seen = 0;
	failfrom = failto = 3;
	rc = slhdsa192s_keygen(bad, bad + SLHDSA192S_PKLEN);
	failfrom = -1;
	check(rc == -1, "keygen returned success though an allocation failed", 3);

	printf("signing with one of its %ld allocations refused (%d places) and verifying with one of %ld: failures, nothing left behind\n",
		total, n, vtotal);
	return fails != 0;
}
