/*
 * libsec's X25519 on the host, built by tests/host/x25519_test.sh:
 *
 *	x25test vectors.txt
 *
 * x25519.c is included, so its static field functions are reachable.
 */
#include "../../../libsec/x25519.c"
#include <stdio.h>
#include <stdlib.h>

static int fails, checks;

static void
unhex(char *s, uchar *b, int n)
{
	unsigned v;
	int i;

	for(i = 0; i < n; i++){
		sscanf(s+2*i, "%2x", &v);
		b[i] = v;
	}
}

static char*
hex(uchar *b)
{
	static char s[2][65];
	static int w;
	int i;

	w ^= 1;
	for(i = 0; i < 32; i++)
		sprintf(s[w]+2*i, "%02x", b[i]);
	return s[w];
}

int
main(int argc, char **argv)
{
	FILE *f;
	static char line[512], w[7][80];
	uchar k[32], u[32], want[32], got[32];
	felem l;
	unsigned long long v;
	int nf, i, nx, nc;

	if(argc != 2 || (f = fopen(argv[1], "r")) == nil){
		fprintf(stderr, "usage: x25test vectors.txt\n");
		return 2;
	}
	nx = nc = 0;
	while(fgets(line, sizeof line, f) != nil){
		nf = sscanf(line, "%79s %79s %79s %79s %79s %79s %79s", w[0], w[1], w[2], w[3], w[4], w[5], w[6]);
		if(nf == 4 && strcmp(w[0], "x25519") == 0){
			unhex(w[1], k, 32);
			unhex(w[2], u, 32);
			unhex(w[3], want, 32);
			x25519(got, k, u);
			checks++;
			nx++;
			if(memcmp(got, want, 32) != 0){
				fails++;
				printf("FAIL: x25519(%s, %s) is %s, OpenSSL's is %s\n", w[1], w[2], hex(got), w[3]);
			}
		}else if(nf == 7 && strcmp(w[0], "contract") == 0){
			for(i = 0; i < 5; i++){
				sscanf(w[1+i], "%llx", &v);
				l[i] = v;
			}
			unhex(w[6], want, 32);
			fcontract(got, l);
			checks++;
			nc++;
			if(memcmp(got, want, 32) != 0){
				fails++;
				if(fails < 12)
					printf("FAIL: limbs %s %s %s %s %s are %s, written %s\n", w[1], w[2], w[3], w[4], w[5], w[6], hex(got));
			}
			/* and a value below p goes in and comes out as it is */
			fexpand(l, want);
			fcontract(got, l);
			checks++;
			if(memcmp(got, want, 32) != 0){
				fails++;
				if(fails < 12)
					printf("FAIL: %s read and written is %s\n", w[6], hex(got));
			}
		}
	}
	fclose(f);
	if(nx < 60 || nc < 800){
		printf("FAIL: only %d X25519 and %d field vectors\n", nx, nc);
		fails++;
	}
	if(fails){
		printf("x25test: %d of %d checks FAILED\n", fails, checks);
		return 1;
	}
	printf("x25test: %d checks passed (%d of OpenSSL's X25519, %d field elements)\n", checks, nx, nc);
	return 0;
}
