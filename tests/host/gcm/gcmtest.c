/*
 * libsec's AES-GCM (aesgcm.c), its GHASH in C and by PMULL
 * (ghasharm64.c) and its counter mode by aes.c and by the AES
 * instructions (aesarm64.c), against OpenSSL's answers
 * (tests/host/gcm/vectors.txt, made by gen.py) and against each other.
 * Built by tests/host/armcrypto_test.sh.
 *
 *	gcmtest vectors.txt	known answers in each configuration, then
 *				random cases compared across them, opened
 *				again, and refused once changed; speeds
 *	gcmtest ct		the C GHASH on a key and data valgrind is told
 *				are secret (-DCTGRIND): any branch or address
 *				that depends on them is reported
 */

#include "../../../libsec/aesgcm.c"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef CTGRIND
#include <valgrind/memcheck.h>
#else
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n)	USED(p)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)	USED(p)
#endif

void aesarm64use(int);
void ghasharm64use(int);

static int fails;

/* the configurations: what aesgcm.c uses */
enum { Call, Pmull, Pmullaes, Nconf };
static char *confname[] = { "C", "PMULL with aes.c", "PMULL and the AES instructions" };

static int
setconf(int c)
{
	aesgcmuseC(c == Call);
	ghasharm64use(c != Call);
	aesarm64use(c == Pmullaes);
	if(c == Call)
		return 1;
	if(!ghasharm64ok())
		return 0;
	return c != Pmullaes || aesarm64ok();
}

static int
unhex(char *s, uchar *b)
{
	int n;
	unsigned v;

	if(strcmp(s, "-") == 0)
		return 0;
	for(n = 0; s[2*n] && s[2*n+1]; n++){
		sscanf(s + 2*n, "%2x", &v);
		b[n] = v;
	}
	return n;
}

static void
gcm(uchar *key, int nkey, uchar *iv, int niv, uchar *aad, int naad, uchar *dat, int ndat, uchar tag[16])
{
	AESGCMstate s;

	setupAESGCMstate(&s, key, nkey, iv, niv);
	aesgcm_encrypt(dat, ndat, aad, naad, tag, &s);
}

static int
ungcm(uchar *key, int nkey, uchar *iv, int niv, uchar *aad, int naad, uchar *dat, int ndat, uchar tag[16])
{
	AESGCMstate s;

	setupAESGCMstate(&s, key, nkey, iv, niv);
	return aesgcm_decrypt(dat, ndat, aad, naad, tag, &s);
}

enum { Max = 5000 };

static void
vectors(char *path)
{
	static char line[4*Max*2 + 4096];
	static uchar key[32], iv[256], aad[256], pt[Max], ct[Max], tag[16], dat[Max], got[16];
	char f[7][2*Max+2];
	int nkey, niv, naad, npt, nct, n, c, ok, ran[Nconf];
	FILE *fp;

	memset(ran, 0, sizeof ran);
	fp = fopen(path, "r");
	if(fp == nil){
		printf("FAIL: cannot open %s\n", path);
		fails++;
		return;
	}
	n = 0;
	while(fgets(line, sizeof line, fp) != nil){
		if(sscanf(line, "%6s %s %s %s %s %s %s", f[0], f[1], f[2], f[3], f[4], f[5], f[6]) != 7 || strcmp(f[0], "gcm") != 0)
			continue;
		nkey = unhex(f[1], key);
		niv = unhex(f[2], iv);
		naad = unhex(f[3], aad);
		npt = unhex(f[4], pt);
		nct = unhex(f[5], ct);
		unhex(f[6], tag);
		n++;
		for(c = 0; c < Nconf; c++){
			if(!setconf(c))
				continue;
			ran[c]++;
			memmove(dat, pt, npt);
			gcm(key, nkey, iv, niv, aad, naad, dat, npt, got);
			ok = npt == nct && memcmp(dat, ct, nct) == 0 && memcmp(got, tag, 16) == 0;
			if(ok)
				ok = ungcm(key, nkey, iv, niv, aad, naad, dat, nct, tag) == 0 && memcmp(dat, pt, npt) == 0;
			if(!ok){
				printf("FAIL: %s: vector %d (key %d, iv %d, aad %d, data %d bytes)\n", confname[c], n, nkey, niv, naad, npt);
				fails++;
			}
		}
	}
	fclose(fp);
	for(c = 0; c < Nconf; c++)
		if(ran[c])
			printf("%s: %d OpenSSL vectors\n", confname[c], ran[c]);
		else
			printf("SKIP: %s: not on this processor\n", confname[c]);
	if(n < 400){
		printf("FAIL: only %d vectors read from %s\n", n, path);
		fails++;
	}
}

static void
rnd(uchar *b, int n)
{
	while(n-- > 0)
		*b++ = rand();
}

/* random cases: the same bytes in every configuration; opened; refused when changed */
static void
random_cases(void)
{
	static uchar key[32], iv[64], aad[100], pt[Max], dat[Nconf][Max], tag[Nconf][16], t2[16];
	int i, c, nkey, niv, naad, npt, have[Nconf], k, bad;

	srand(7);
	bad = 0;
	for(i = 0; i < 3000; i++){
		nkey = 16 + 8*(rand()%3);
		niv = rand()%5 == 0 ? 1 + rand()%64 : 12;
		naad = rand()%100;
		npt = rand()%4 == 0 ? rand()%Max : rand()%100;
		rnd(key, nkey); rnd(iv, niv); rnd(aad, naad); rnd(pt, npt);
		for(c = 0; c < Nconf; c++){
			have[c] = setconf(c);
			if(!have[c])
				continue;
			memmove(dat[c], pt, npt);
			gcm(key, nkey, iv, niv, aad, naad, dat[c], npt, tag[c]);
			if(c > 0 && (memcmp(dat[c], dat[0], npt) != 0 || memcmp(tag[c], tag[0], 16) != 0)){
				if(bad++ < 5)
					printf("FAIL: %s differs from C: case %d (key %d, iv %d, aad %d, data %d)\n", confname[c], i, nkey, niv, naad, npt);
			}
			/* a byte changed, of the ciphertext, the aad or the tag: refused, the data left */
			{
				static uchar d2[Max], a2[100], before[Max];

				memmove(d2, dat[c], npt);
				memmove(a2, aad, naad);
				memmove(t2, tag[c], 16);
				k = rand()%3;
				if(k == 0 && npt > 0)
					d2[rand()%npt] ^= 1 << (rand()%8);
				else if(k == 1 && naad > 0)
					a2[rand()%naad] ^= 1 << (rand()%8);
				else
					t2[rand()%16] ^= 1 << (rand()%8);
				memmove(before, d2, npt);
				if(ungcm(key, nkey, iv, niv, a2, naad, d2, npt, t2) != -1 || memcmp(before, d2, npt) != 0){
					if(bad++ < 5)
						printf("FAIL: %s: a changed case %d was taken, or its data changed\n", confname[c], i);
				}
			}
		}
	}
	/* round trips, the aad untouched */
	srand(9);
	for(i = 0; i < 500; i++){
		nkey = 16 + 8*(rand()%3);
		naad = rand()%100;
		npt = rand()%Max;
		rnd(key, nkey); rnd(iv, 12); rnd(aad, naad); rnd(pt, npt);
		for(c = 0; c < Nconf; c++){
			if(!setconf(c))
				continue;
			memmove(dat[c], pt, npt);
			gcm(key, nkey, iv, 12, aad, naad, dat[c], npt, tag[c]);
			if(ungcm(key, nkey, iv, 12, aad, naad, dat[c], npt, tag[c]) != 0 || memcmp(dat[c], pt, npt) != 0){
				if(bad++ < 5)
					printf("FAIL: %s: round trip %d\n", confname[c], i);
			}
		}
	}
	if(bad)
		fails++;
	else
		printf("random: 3000 cases the same in each configuration and refused once changed; 500 round trips\n");
}

static void
speeds(void)
{
	static uchar key[32], iv[12], buf[16384], tag[16];
	AESGCMstate s;
	clock_t t0;
	double secs;
	int c, n;

	rnd(key, 32); rnd(iv, 12); rnd(buf, sizeof buf);
	for(c = 0; c < Nconf; c++){
		if(!setconf(c))
			continue;
		setupAESGCMstate(&s, key, 32, iv, 12);
		t0 = clock();
		n = 0;
		do{
			aesgcm_encrypt(buf, sizeof buf, nil, 0, tag, &s);
			n++;
			secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
		}while(secs < 0.5);
		printf("speed: AES-256-GCM, %s: %.0f MB/s\n", confname[c], n * (double)sizeof buf / secs / 1e6);
	}
}

/* the C GHASH with its key and data secret: valgrind reports any use of them in a branch or an address */
static void
ct(void)
{
	static uchar y[16], h[16], data[4096];

	rnd(h, 16); rnd(data, sizeof data);
	VALGRIND_MAKE_MEM_UNDEFINED(h, sizeof h);
	VALGRIND_MAKE_MEM_UNDEFINED(data, sizeof data);
	VALGRIND_MAKE_MEM_UNDEFINED(y, sizeof y);
	ghashct(y, h, data, sizeof data);
	VALGRIND_MAKE_MEM_DEFINED(y, sizeof y);
	printf("%02x\n", y[0]);
}

int
main(int argc, char **argv)
{
	if(argc > 1 && strcmp(argv[1], "ct") == 0){
		ct();
		return 0;
	}
	if(argc < 2){
		fprintf(stderr, "usage: gcmtest vectors.txt | ct\n");
		return 2;
	}
	vectors(argv[1]);
	random_cases();
	speeds();
	setconf(Pmullaes);
	return fails != 0;
}
