/*
 * The shared audio device's arithmetic (emu/port/audiomix.c) on the
 * host: G.711 against its known values and its own round trip, linear
 * and 8-bit samples both ways, rate conversion (a tone keeps its
 * frequency and shape; a stream converted in pieces is the stream
 * converted whole), the queues (wrapping, the oldest dropped or the
 * newest refused), and the mix (summed, ramped, clipped).
 * Run by tests/host/audiomix_test.sh.
 */
#include "lib9.h"
#include "audiomix.h"
#include <stdio.h>
#include <math.h>

static int fails;

#define CHECK(c, ...) do { if(!(c)){ printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } } while(0)

static void
g711(void)
{
	Afmt u = {8000, 1, 8, Aulaw}, a = {8000, 1, 8, Aalaw};
	uchar b[256], o[256];
	short s[512];
	int i, ok, mono;

	for(i = 0; i < 256; i++)
		b[i] = i;
	decodepcm(&u, b, 256, s);
	CHECK(s[0] == -32124 && s[2*0x80] == 32124, "mu-law extremes %d %d", s[0], s[2*0x80]);
	encodepcm(&u, s, 256, o);
	ok = 1;
	for(i = 0; i < 256; i++)
		if(o[i] != i && !(i == 0x7F && o[i] == 0xFF))	/* mu-law's two zeros */
			ok = 0;
	CHECK(ok, "mu-law: a code decoded and encoded is not itself");
	mono = 1;
	for(i = 0; i < 127; i++)	/* 0x00..0x7E rise; 0x80..0xFE fall */
		if(s[2*i] >= s[2*(i+1)] || s[2*(0x80+i)] <= s[2*(0x81+i)])
			mono = 0;
	CHECK(mono, "mu-law decoding is not monotonic");
	s[0] = s[1] = 0;
	encodepcm(&u, s, 1, o);
	CHECK(o[0] == 0xFF, "mu-law silence is 0x%02x, not 0xff", o[0]);

	decodepcm(&a, b, 256, s);
	CHECK(s[2*0x2A] == -32256 && s[2*0xAA] == 32256, "A-law extremes %d %d", s[2*0x2A], s[2*0xAA]);
	encodepcm(&a, s, 256, o);
	ok = 1;
	for(i = 0; i < 256; i++)
		if(o[i] != i)
			ok = 0;
	CHECK(ok, "A-law: a code decoded and encoded is not itself");
	s[0] = s[1] = 0;
	encodepcm(&a, s, 1, o);
	CHECK(o[0] == 0xD5, "A-law silence is 0x%02x, not 0xd5", o[0]);
}

static void
linear(void)
{
	Afmt st = {48000, 2, 16, Apcm}, mo = {16000, 1, 16, Apcm}, b8 = {8000, 1, 8, Apcm};
	uchar in[8] = {0x34, 0x12, 0xCC, 0xED, 0x00, 0x80, 0xFF, 0x7F}, out[8];
	short s[8];
	int n;

	n = decodepcm(&st, in, 8, s);
	CHECK(n == 2 && s[0] == 0x1234 && s[1] == -0x1234 && s[2] == -32768 && s[3] == 32767,
		"16-bit stereo decoded %d: %d %d %d %d", n, s[0], s[1], s[2], s[3]);
	n = encodepcm(&st, s, 2, out);
	CHECK(n == 8 && memcmp(in, out, 8) == 0, "16-bit stereo does not come back as it went");
	n = decodepcm(&st, in, 7, s);
	CHECK(n == 1, "a part frame was decoded (%d frames from 7 bytes)", n);

	n = decodepcm(&mo, in, 2, s);
	CHECK(n == 1 && s[0] == 0x1234 && s[1] == 0x1234, "mono is not both channels");
	s[0] = 1000; s[1] = 3000;
	n = encodepcm(&mo, s, 1, out);
	CHECK(n == 2 && (short)(out[0] | out[1] << 8) == 2000, "stereo to mono is not the average");

	in[0] = 0; in[1] = 128; in[2] = 255;
	n = decodepcm(&b8, in, 3, s);
	CHECK(n == 3 && s[0] == -32768 && s[2] == 0 && s[4] == 127 << 8, "8-bit unsigned decoded %d %d %d", s[0], s[2], s[4]);
	n = encodepcm(&b8, s, 3, out);
	CHECK(n == 3 && out[0] == 0 && out[1] == 128 && out[2] == 255, "8-bit does not come back");
}

/* a tone of hz at rate, n frames from frame t0 */
static void
tone(short *s, int n, int rate, double hz, int t0)
{
	int i;

	for(i = 0; i < n; i++)
		s[2*i] = s[2*i+1] = 12000 * sin(2*M_PI*hz*(t0+i)/rate);
}

static int
crossings(short *s, int n)
{
	int i, c;

	c = 0;
	for(i = 1; i < n; i++)
		if((s[2*(i-1)] < 0) != (s[2*i] < 0))
			c++;
	return c;
}

static void
rates(void)
{
	static short in[2*48000], out[2*200000], piece[2*200000], want[2*200000];
	Resamp r;
	int n, m, i, k, worst, cin, cout, ri, ro, pairs[][2] = {{16000, 48000}, {48000, 16000}, {44100, 48000}, {8000, 48000}, {48000, 44100}};
	double err;

	/* equal rates: the stream, one frame late */
	tone(in, 1000, 48000, 440, 0);
	resampinit(&r, 48000, 48000);
	n = resample(&r, in, 1000, out);
	CHECK(n == 1000 && memcmp(out + 2, in, 999 * 4) == 0, "equal rates changed the samples");

	for(k = 0; k < (int)nelem(pairs); k++){
		ri = pairs[k][0];
		ro = pairs[k][1];
		tone(in, ri, ri, 440, 0);	/* one second */
		resampinit(&r, ri, ro);
		CHECK(resampmax(&r, ri) >= ro, "resampmax too small");
		n = resample(&r, in, ri, out);
		CHECK(n >= ro - 2 && n <= ro + 2, "%d to %d: %d frames for a second", ri, ro, n);
		cin = crossings(in, ri);
		cout = crossings(out, n);
		CHECK(cout >= cin - 2 && cout <= cin + 2, "%d to %d: a 440 Hz tone crossed %d times, not %d", ri, ro, cout, cin);
		/* against the tone itself at the output rate, allowing the frame of delay */
		tone(want, n, ro, 440, 0);
		worst = 0;
		for(i = 2; i < n - 2; i++){
			double t = (double)i * ri / ro - 1;	/* the input time this output stands for */
			if(t < 0)	/* before the stream's first frame, which is all it can repeat */
				continue;
			double v = 12000 * sin(2*M_PI*440*t/ri);
			err = fabs(out[2*i] - v);
			if(err > worst)
				worst = err;
		}
		/* linear interpolation's own worst error, A (wh)^2 / 8, and a sample's rounding */
		{
			double wh = 2*M_PI*440/ri, bound = 12000*wh*wh/8 + 2;
			CHECK(worst <= bound, "%d to %d: off the tone by %d, more than interpolation's %.0f", ri, ro, worst, bound);
		}

		/* in pieces of awkward sizes, the same as whole */
		resampinit(&r, ri, ro);
		m = 0;
		for(i = 0; i < ri; i += 37 + i % 101){
			int len = 37 + i % 101;
			if(i + len > ri)
				len = ri - i;
			m += resample(&r, in + 2*i, len, piece + 2*m);
		}
		CHECK(m == n && memcmp(piece, out, n * 4) == 0, "%d to %d: in pieces %d frames, whole %d, or different", ri, ro, m, n);
	}
}

static void
rings(void)
{
	short buf[2*8], s[2*20], d[2*20];
	uchar bb[8], bs[20], bd[20];
	Fring f;
	Bring b;
	int i, n;

	for(i = 0; i < 20; i++){
		s[2*i] = s[2*i+1] = i;
		bs[i] = i;
	}
	fringinit(&f, buf, 8);
	n = fringput(&f, s, 5, 0);
	n += fringput(&f, s + 10, 5, 0);
	CHECK(n == 8 && f.len == 8, "put without dropping took %d of 10 into 8", n);
	n = fringget(&f, d, 3);
	CHECK(n == 3 && d[0] == 0 && d[4] == 2, "got the wrong frames first");
	fringput(&f, s + 2*15, 3, 0);	/* wraps */
	n = fringget(&f, d, 20);
	CHECK(n == 8 && d[2*0] == 3 && d[2*1] == 4 && d[2*2] == 5 && d[2*4] == 7 && d[2*5] == 15 && d[2*7] == 17, "wrapped put or get out of order");
	fringput(&f, s, 6, 1);
	fringput(&f, s + 2*6, 6, 1);	/* drops the oldest four */
	n = fringget(&f, d, 20);
	CHECK(n == 8 && d[0] == 4 && d[2*7] == 11, "dropping kept the wrong frames: %d..%d", d[0], d[2*7]);
	n = fringput(&f, s, 20, 1);
	n = fringget(&f, d, 20);
	CHECK(n == 8 && d[0] == 12 && d[2*7] == 19, "more than fits with dropping did not keep the newest");

	bringinit(&b, bb, 8);
	bringput(&b, bs, 6, 1);
	bringput(&b, bs + 6, 6, 1);
	n = bringget(&b, bd, 20);
	CHECK(n == 8 && bd[0] == 4 && bd[7] == 11, "byte queue dropped the wrong bytes");
	n = bringput(&b, bs, 20, 0);
	CHECK(n == 8, "byte queue without dropping took %d", n);
}

static void
mix(void)
{
	short a[2*4] = {10000, 10000, 30000, -30000, 100, 100, 0, 0};
	short b[2*4] = {10000, -10000, 30000, -30000, 100, 100, 0, 0};
	short o[2*4];
	int acc[2*4];

	memset(acc, 0, sizeof acc);
	mixadd(acc, a, 4, Gainone, Gainone);
	mixadd(acc, b, 4, Gainone, Gainone);
	mixclip(acc, o, 4);
	CHECK(o[0] == 20000 && o[1] == 0, "not summed: %d %d", o[0], o[1]);
	CHECK(o[2] == 32767 && o[3] == -32768, "not clipped: %d %d", o[2], o[3]);
	memset(acc, 0, sizeof acc);
	mixadd(acc, a, 4, 0, Gainone);
	CHECK(acc[0] == 0 && acc[4] == 100 * 2 / 4, "the gain does not ramp from 0: %d %d", acc[0], acc[4]);
	memset(acc, 0, sizeof acc);
	mixadd(acc, a, 4, Gainone/4, Gainone/4);
	CHECK(acc[0] == 2500, "a quarter gain gave %d", acc[0]);
}

int
main(void)
{
	g711();
	linear();
	rates();
	rings();
	mix();
	if(fails){
		printf("%d failed\n", fails);
		return 1;
	}
	printf("PASS: audiomix\n");
	return 0;
}
