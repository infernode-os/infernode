/*
 * os/amd64/fmttest.c -- snprint writes to the buffer it was given.
 *
 * The formatter takes a sink: print() writes to the console, snprint()
 * and vsnprint() to a buffer.  A verb that bypassed the sink (as %p did
 * through consprinthex) would leave the buffer empty and report the
 * wrong length; these checks make that visible.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"

static int
eq(char *got, char *want, int n)
{
	return strcmp(got, want) == 0 && n == strlen(want);
}

static int
check(char *fmt, ...);

void
fmttest(void)
{
	char b[64];
	int n, ok;

	ok = 1;
	n = snprint(b, sizeof(b), "%p", (void*)0x1234);
	ok &= eq(b, "0000000000001234", n);
	n = snprint(b, sizeof(b), "%#p", (void*)0x1234);
	ok &= eq(b, "0x0000000000001234", n);
	n = snprint(b, sizeof(b), "%d", -42);
	ok &= eq(b, "-42", n);
	n = snprint(b, sizeof(b), "%lud", 123456789);
	ok &= eq(b, "123456789", n);
	n = snprint(b, sizeof(b), "%s %c", "hi", '!');
	ok &= eq(b, "hi !", n);
	n = snprint(b, sizeof(b), "%lux", 0xdeadbeefUL);
	ok &= eq(b, "00000000deadbeef", n);

	if(ok)
		consprint("fmttest passed\n");
	else
		consprint("fmttest failed\n");
}
