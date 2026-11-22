/*
 * libkeyring/ed25519alg.c's Ed25519 on the host: known answers and
 * refusals, built with the undefined-behaviour sanitizer by
 * tests/host/ed25519_test.sh.  The file is Keyring's glue and the
 * arithmetic in one; what the glue needs of lib9 is stubbed here
 * (nothing below calls it), and libmp is the tree's.
 */
#include <stdio.h>
#include "lib9.h"
#include <mp.h>
#include <libsec.h>

void	ed25519_raw_sign(uchar sig[64], const uchar seed[32], const uchar *msg, ulong msglen);
int	ed25519_raw_verify(const uchar sig[64], const uchar pk[32], const uchar *msg, ulong msglen);
void	ed25519_raw_pubkey(uchar pk[32], const uchar seed[32]);

/* the glue's needs of lib9 and libsec that nothing below reaches */
static void	no(char *s) { fprintf(stderr, "edtest: %s called\n", s); exit(3); }
int	enc64(char *o, int n, uchar *i, int m) { USED(o); USED(n); USED(i); USED(m); no("enc64"); return 0; }
int	dec64(uchar *o, int n, char *i, int m) { USED(o); USED(n); USED(i); USED(m); no("dec64"); return 0; }
int	fprint(int fd, char *fmt, ...) { USED(fd); USED(fmt); return 0; }
void	genrandom(uchar *p, int n) { USED(p); USED(n); no("genrandom"); }

/* libmp's (the signature's S is made with it) */
void*
mallocz(ulong n, int clr)
{
	USED(clr);
	return calloc(1, n);
}

void
sysfatal(char *fmt, ...)
{
	fprintf(stderr, "edtest: sysfatal: %s\n", fmt);
	exit(3);
}

static int fails, checks;

static void
check(int ok, char *what, int i)
{
	checks++;
	if(!ok){
		fails++;
		if(fails < 20)
			printf("FAIL: %s (vector %d)\n", what, i);
	}
}

static int
unhex(char *s, uchar *out, int max)
{
	int n, c, v;

	if(strcmp(s, "-") == 0)
		return 0;
	for(n = 0; s[0] != 0 && s[1] != 0; s += 2, n++){
		if(n >= max)
			return -1;
		v = 0;
		for(c = 0; c < 2; c++){
			v <<= 4;
			if(s[c] >= '0' && s[c] <= '9')
				v |= s[c] - '0';
			else if(s[c] >= 'a' && s[c] <= 'f')
				v |= s[c] - 'a' + 10;
			else
				return -1;
		}
		out[n] = v;
	}
	return n;
}

/* the group's order, little-endian: S + L is the same signature to an implementation that does not ask S < L */
static uchar L[32] = {
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
};

int
main(int argc, char **argv)
{
	FILE *f;
	static char line[4096], sseed[80], spk[80], smsg[2048], ssig[160];
	uchar seed[32], pk[32], msg[1024], sig[64], out[64], bad[64], pk2[32];
	int i, n, j, c;

	if(argc != 2){
		fprintf(stderr, "usage: edtest vectors.txt\n");
		return 2;
	}
	f = fopen(argv[1], "r");
	if(f == NULL){
		perror(argv[1]);
		return 2;
	}
	for(i = 0; fgets(line, sizeof line, f) != NULL; i++){
		if(sscanf(line, "%79s %79s %2047s %159s", sseed, spk, smsg, ssig) != 4
		|| unhex(sseed, seed, 32) != 32 || unhex(spk, pk, 32) != 32
		|| (n = unhex(smsg, msg, sizeof msg)) < 0 || unhex(ssig, sig, 64) != 64){
			printf("FAIL: vector %d is not one\n", i);
			return 2;
		}
		ed25519_raw_pubkey(pk2, seed);
		check(memcmp(pk2, pk, 32) == 0, "the public key of a seed", i);
		ed25519_raw_sign(out, seed, msg, n);
		check(memcmp(out, sig, 64) == 0, "a signature, byte for byte", i);
		check(ed25519_raw_verify(sig, pk, msg, n) == 1, "a signature verifies", i);

		/* each half changed, the message changed, another key's */
		memmove(bad, sig, 64);
		bad[i % 32] ^= 1 << (i % 8);
		check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with R changed is refused", i);
		memmove(bad, sig, 64);
		bad[32 + i % 32] ^= 1 << (i % 8);
		check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with S changed is refused", i);
		if(n > 0){
			msg[i % n] ^= 0x80;
			check(ed25519_raw_verify(sig, pk, msg, n) != 1, "a signature of another message is refused", i);
			msg[i % n] ^= 0x80;
		}
		check(ed25519_raw_verify(sig, pk, msg, n + 1) != 1, "a signature of a longer message is refused", i);
		memmove(pk2, pk, 32);
		pk2[i % 32] ^= 4;
		check(ed25519_raw_verify(sig, pk2, msg, n) != 1, "a signature under another key is refused", i);

		/* S + L (RFC 8032 5.1.7: S must be below L) */
		memmove(bad, sig, 64);
		c = 0;
		for(j = 0; j < 32; j++){
			c += bad[32+j] + L[j];
			bad[32+j] = c;
			c >>= 8;
		}
		if(c == 0)
			check(ed25519_raw_verify(bad, pk, msg, n) != 1, "a signature with the order added to S is refused", i);
	}
	fclose(f);
	if(i < 100){
		printf("FAIL: only %d vectors read\n", i);
		return 1;
	}
	if(fails){
		printf("ed25519: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("ed25519: %d vectors, %d checks\n", i, checks);
	return 0;
}
