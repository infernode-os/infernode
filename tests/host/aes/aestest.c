/*
 * libsec's AES, aes.c's table code and aesarm64.c's ARMv8 instructions,
 * against FIPS-197 and NIST SP 800-38A, and against each other.
 * Built by tests/host/armcrypto_test.sh.
 */
#include "../../../libsec/aes.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void aesarm64use(int);	/* aesarm64.c, built beside this */

static int failed;

static void
hex(const char *s, uchar *b, int n)
{
	int i;
	unsigned v;

	for(i = 0; i < n; i++){
		sscanf(s + 2*i, "%2x", &v);
		b[i] = v;
	}
}

static void
check(const char *what, uchar *got, uchar *want, int n)
{
	if(memcmp(got, want, n) != 0){
		printf("FAIL: %s\n", what);
		failed = 1;
	}
}

static void
fips197(const char *path)
{
	static struct { int kb; const char *ct; } v[] = {
		{16, "69c4e0d86a7b0430d8cdb78070b4c55a"},
		{24, "dda97ca4864cdfe06eaf70a0ec0d7191"},
		{32, "8ea2b7ca516745bfeafc49904b496089"},
	};
	uchar key[32], pt[16], ct[16], out[16], want[16], iv[16];
	char what[64];
	AESstate s;
	int i, j;

	for(i = 0; i < 32; i++)
		key[i] = i;
	hex("00112233445566778899aabbccddeeff", pt, 16);
	for(j = 0; j < 3; j++){
		hex(v[j].ct, want, 16);
		memset(iv, 0, 16);
		setupAESstate(&s, key, v[j].kb, iv);
		aesEncryptBlock(&s, pt, out);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d block", path, 8*v[j].kb);
		check(what, out, want, 16);
		/* CBC with a zero IV is the block cipher on its first block */
		memcpy(ct, pt, 16);
		aesCBCencrypt(ct, 16, &s);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d through CBC", path, 8*v[j].kb);
		check(what, ct, want, 16);
		memset(iv, 0, 16);
		setupAESstate(&s, key, v[j].kb, iv);
		aesCBCdecrypt(ct, 16, &s);
		snprintf(what, sizeof what, "%s: FIPS-197 AES-%d decrypted", path, 8*v[j].kb);
		check(what, ct, pt, 16);
	}
}

static void
sp80038a(const char *path)
{
	uchar key[32], iv[16], pt[64], ct[64], buf[64];
	char what[64];
	AESstate s;

	hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4", key, 32);
	hex("000102030405060708090a0b0c0d0e0f", iv, 16);
	hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
	    "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710", pt, 64);
	hex("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
	    "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b", ct, 64);
	setupAESstate(&s, key, 32, iv);
	memcpy(buf, pt, 64);
	aesCBCencrypt(buf, 64, &s);
	snprintf(what, sizeof what, "%s: SP 800-38A F.2.5 CBC-AES256 encrypt", path);
	check(what, buf, ct, 64);
	setupAESstate(&s, key, 32, iv);
	aesCBCdecrypt(buf, 64, &s);
	snprintf(what, sizeof what, "%s: SP 800-38A F.2.6 CBC-AES256 decrypt", path);
	check(what, buf, pt, 64);
}

static void
cross(void)
{
	uchar key[32], iv[16], buf[1000], a[1000], b[1000];
	AESstate s;
	int t, i, n, kb, bad;

	srand(1);
	bad = 0;
	for(t = 0; t < 6000; t++){
		kb = 16 + 8*(t%3);
		for(i = 0; i < 32; i++)
			key[i] = rand();
		for(i = 0; i < 16; i++)
			iv[i] = rand();
		n = rand() % 1000;
		for(i = 0; i < n; i++)
			buf[i] = rand();
		memcpy(a, buf, n);
		memcpy(b, buf, n);
		aesarm64use(0);
		setupAESstate(&s, key, kb, iv);
		aesCBCencrypt(a, n, &s);
		aesarm64use(1);
		setupAESstate(&s, key, kb, iv);
		aesCBCencrypt(b, n, &s);
		if(memcmp(a, b, n) != 0)
			bad++;
		/* and back, each with the other's */
		aesarm64use(t & 1);
		setupAESstate(&s, key, kb, iv);
		aesCBCdecrypt(b, n, &s);
		if(memcmp(b, buf, n) != 0)
			bad++;
	}
	if(bad){
		printf("FAIL: the two paths disagree on %d of 12000 random CBC runs\n", bad);
		failed = 1;
	}else
		printf("PASS: the two paths agree on 6000 random keys, IVs and lengths, both ways\n");
}

static double
speed(int dec)
{
	static uchar buf[32768];
	uchar key[32] = {1}, iv[16] = {0};
	AESstate s;
	clock_t t0;
	int n;

	setupAESstate(&s, key, 32, iv);
	t0 = clock();
	n = 0;
	while(clock() - t0 < CLOCKS_PER_SEC/2){
		if(dec)
			aesCBCdecrypt(buf, sizeof buf, &s);
		else
			aesCBCencrypt(buf, sizeof buf, &s);
		n++;
	}
	return n * (double)sizeof buf / 1e6 / ((double)(clock() - t0) / CLOCKS_PER_SEC);
}

int
main(void)
{
	double te, td, ae, ad;

	aesarm64use(0);
	fips197("tables");
	sp80038a("tables");
	te = speed(0);
	td = speed(1);
	if(aesarm64ok() || (aesarm64use(1), aesarm64ok())){
		aesarm64use(1);
		fips197("ARMv8");
		sp80038a("ARMv8");
		cross();
		ae = speed(0);
		ad = speed(1);
		printf("AES-256-CBC MB/s: tables %.0f encrypt %.0f decrypt; ARMv8 %.0f encrypt %.0f decrypt\n", te, td, ae, ad);
	}else
		printf("SKIP: no ARMv8 AES here; tables %.0f encrypt %.0f decrypt MB/s\n", te, td);
	if(!failed)
		printf("PASS: FIPS-197 and SP 800-38A vectors on every path\n");
	return failed;
}
