/*
 * libkern's memmove, memcpy and memset (the native kernels' own),
 * built on the host under other names, against byte-by-byte
 * references: every alignment of source and destination, lengths 0
 * to 300 and some past it, overlaps either way at every distance
 * up to 40, and the bytes either side of the destination untouched.
 * See tests/host/libkern_copy_test.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void*	kmemmove(void*, void*, unsigned long);
void*	kmemcpy(void*, void*, unsigned long);
void*	kmemset(void*, int, unsigned long);

enum { Pad = 64, Max = 5000 };

static unsigned char src[Max+2*Pad], dst[Max+2*Pad], ref[Max+2*Pad], buf[Max+2*Pad];
static long checks, fails;

static void
fill(unsigned char *p, int n, unsigned seed)
{
	int i;

	for(i = 0; i < n; i++){
		seed = seed*1103515245 + 12345;
		p[i] = seed >> 16;
	}
}

static void
fail(const char *what, int a, int b, int n, int at)
{
	if(fails++ < 20)
		fprintf(stderr, "FAIL: %s a=%d b=%d n=%d: byte %d wrong\n", what, a, b, n, at);
}

static void
compare(const char *what, unsigned char *got, unsigned char *want, int len, int a, int b, int n)
{
	int i;

	checks++;
	for(i = 0; i < len; i++)
		if(got[i] != want[i]){
			fail(what, a, b, n, i);
			return;
		}
}

static const int lens[] = {1000, 1023, 1024, 1025, 4093, 4096, 4099, Max-16};

static void
apart(int n)
{
	int so, dof, i;
	void *r;

	for(so = 0; so < 16; so++)
		for(dof = 0; dof < 16; dof++){
			fill(src, sizeof src, n*256 + so*16 + dof);
			fill(dst, sizeof dst, 7 + n);
			memcpy(ref, dst, sizeof dst);
			for(i = 0; i < n; i++)
				ref[Pad+dof+i] = src[Pad+so+i];
			r = kmemmove(dst+Pad+dof, src+Pad+so, n);
			if(r != dst+Pad+dof)
				fail("memmove result", so, dof, n, -1);
			compare("memmove apart", dst, ref, sizeof dst, so, dof, n);

			fill(dst, sizeof dst, 11 + n);
			memcpy(ref, dst, sizeof dst);
			for(i = 0; i < n; i++)
				ref[Pad+dof+i] = src[Pad+so+i];
			r = kmemcpy(dst+Pad+dof, src+Pad+so, n);
			if(r != dst+Pad+dof)
				fail("memcpy result", so, dof, n, -1);
			compare("memcpy", dst, ref, sizeof dst, so, dof, n);
		}
}

static void
overlap(int n)
{
	int base, delta, i;
	unsigned char tmp[Max];

	for(base = 0; base < 16; base++)
		for(delta = -40; delta <= 40; delta++){
			int s = Pad + 40 + base, d = s + delta;
			if(s + n > (int)sizeof buf || d + n > (int)sizeof buf)
				continue;
			fill(buf, sizeof buf, n*97 + base*81 + delta + 40);
			memcpy(ref, buf, sizeof buf);
			for(i = 0; i < n; i++)
				tmp[i] = ref[s+i];
			for(i = 0; i < n; i++)
				ref[d+i] = tmp[i];
			kmemmove(buf+d, buf+s, n);
			compare("memmove overlap", buf, ref, sizeof buf, base, delta, n);
		}
}

static void
set(int n)
{
	static const int cs[] = {0, 0xA5, -1, 0x1FF, 0x80};
	int o, k, i;
	void *r;

	for(o = 0; o < 16; o++)
		for(k = 0; k < 5; k++){
			fill(dst, sizeof dst, n + o + k);
			memcpy(ref, dst, sizeof dst);
			for(i = 0; i < n; i++)
				ref[Pad+o+i] = (unsigned char)cs[k];
			r = kmemset(dst+Pad+o, cs[k], n);
			if(r != dst+Pad+o)
				fail("memset result", o, cs[k], n, -1);
			compare("memset", dst, ref, sizeof dst, o, cs[k], n);
		}
}

int
main(void)
{
	int n, i;

	for(n = 0; n <= 300; n++){
		apart(n);
		overlap(n);
		set(n);
	}
	for(i = 0; i < (int)(sizeof lens/sizeof lens[0]); i++){
		apart(lens[i]);
		overlap(lens[i]);
		set(lens[i]);
	}
	printf("%ld checks, %ld failed\n", checks, fails);
	return fails != 0;
}
