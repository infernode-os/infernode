#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * Known-answer test for P-384 (secp384r1) ECDH, cross-validated against
 * OpenSSL 3.x (an independent reference): p384_ecdh(d, Q) must equal the
 * shared secret OpenSSL's `pkeyutl -derive` produced for the same private
 * scalar d and peer public point Q.  Single-line hex to avoid any
 * line-split transcription error.
 */
static char *dIUT_hex   = "37baf696b92be4f4ff790f36617b716b718572daa46841040554962f36f9222800cc27002487f7d3df62a9519c4e7970";
static char *QCAVSx_hex = "1b447b404cd7baf8a96453ef52de61229256ccf504d454c19f23556bd7f15d7ba16c5451f10c68bd2ce5ab8a06685a31";
static char *QCAVSy_hex = "f75b8518f44b14f55d151230d4f1074d5059767500b8216f1ca31ec3e90d2c024a04d56e730d127439995fc14b23d956";
static char *ZIUT_hex   = "341483532711a09d2256c7cca37067c162ef819e4811a6dc2da9197bc057fef9fe7320ff99687e6ab0f7590a5c364ace";

/*
 * Host-side glue normally supplied by the emu platform layer (not the static
 * libs) when a standalone test links libsec/libmp directly.  No-op locks are
 * fine for this single-threaded harness.
 */
void *mallocz(ulong n, int clr){ void *p = malloc(n); if(p != nil && clr) memset(p, 0, n); return p; }
void _genrandomqlock(void){}
void _genrandomqunlock(void){}
/* entropy leaves for genrandom's X9.17 path; only p384_keygen needs randomness,
 * and the round-trip check is correct for any valid scalar, so a simple PRNG is
 * sufficient here (this stub is test-only, never compiled into the library). */
ulong truerand(void){ static ulong s = 0x2545F491UL; s = s*1664525UL + 1013904223UL; return s; }
vlong osnsec(void){ return 0; }

static void
fromhex(char *s, uchar *out, int n)
{
	int i, hi, lo;

	for(i = 0; i < n; i++){
		hi = s[2*i];   hi = hi <= '9' ? hi - '0' : (hi | 0x20) - 'a' + 10;
		lo = s[2*i+1]; lo = lo <= '9' ? lo - '0' : (lo | 0x20) - 'a' + 10;
		out[i] = (uchar)((hi << 4) | lo);
	}
}

void
main(void)
{
	uchar d[48], z[48], got[48];
	uchar da[48], db[48], sab[48], sba[48];
	ECpoint384 Q, A, B, bad;
	int fails;

	fails = 0;
	fromhex(dIUT_hex, d, 48);
	fromhex(QCAVSx_hex, Q.x, 48);
	fromhex(QCAVSy_hex, Q.y, 48);
	fromhex(ZIUT_hex, z, 48);

	/* 1. NIST CAVP known-answer: ecdh(d, QCAVS) == ZIUT */
	if(p384_ecdh(got, d, &Q) != 0){
		print("FAIL: p384_ecdh returned error on KAT\n");
		fails++;
	}else if(memcmp(got, z, 48) != 0){
		print("FAIL: P-384 ECDH KAT shared-secret mismatch\n");
		fails++;
	}else
		print("PASS: P-384 ECDH known-answer (OpenSSL cross-validated)\n");

	/* 2. round-trip: ecdh(a, B.pub) == ecdh(b, A.pub) */
	if(p384_keygen(da, &A) != 0 || p384_keygen(db, &B) != 0){
		print("FAIL: p384_keygen returned error\n");
		fails++;
	}else{
		if(p384_ecdh(sab, da, &B) != 0 || p384_ecdh(sba, db, &A) != 0){
			print("FAIL: p384_ecdh error in round-trip\n");
			fails++;
		}else if(memcmp(sab, sba, 48) != 0){
			print("FAIL: P-384 ECDH round-trip mismatch\n");
			fails++;
		}else
			print("PASS: P-384 ECDH round-trip (keygen x2)\n");
	}

	/* 3. invalid-curve rejection: a perturbed peer point must be refused */
	bad = Q;
	bad.x[47] ^= 1;	/* no longer satisfies the curve equation */
	if(p384_ecdh(got, d, &bad) == 0){
		print("FAIL: P-384 ECDH accepted an off-curve point\n");
		fails++;
	}else
		print("PASS: P-384 ECDH rejects off-curve point\n");

	if(fails == 0){
		print("ALL P-384 ECDH TESTS PASS\n");
		exits(nil);
	}
	print("%d P-384 ECDH TEST(S) FAILED\n", fails);
	exits("fail");
}
