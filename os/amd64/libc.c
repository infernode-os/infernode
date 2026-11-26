/*
 * os/amd64/libc.c -- the few libc entry points libinterp and the
 * imported os/port files expect the C library to have supplied.
 *
 * This kernel has no C library.  Everything else those files need --
 * memcpy, strlen, strcmp -- is in mem.c, which must stay freestanding
 * because the compiler emits calls to it; these are not emitted by the
 * compiler, so they can use the kernel's headers and its types.
 *
 * None of them touches floating point.  strtol and strtoul are integer
 * conversions by definition; charstod, atof and printf's %f are the
 * ones that need FP, and they live in libkernfp and libmath.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

char*
strrchr(char *s, int c)
{
	char *r;

	r = nil;
	do {
		if(*s == (char)c)
			r = (char*)s;
	} while(*s++ != 0);
	return r;
}

char*
strstr(char *s, char *t)
{
	int i, n;

	n = strlen(t);
	for(; *s != 0; s++){
		for(i = 0; i < n && s[i] == t[i]; i++)
			;
		if(i == n)
			return (char*)s;
	}
	return nil;
}

/*
 * strtol and strtoul saturate rather than wrap.
 *
 * libinterp/string.c's strtoint() converts a Limbo string with
 * strtol() and then clamps to the 32-bit range.  It depends on the
 * conversion saturating at the long limits: an unsigned accumulator
 * that wraps turns "18446744073709551616" into 0, and the runtime hands
 * a program an integer it never wrote.  There is no errno here, so
 * saturation is the whole contract.
 */
static int
digit(int c, int base)
{
	int d;

	if(c >= '0' && c <= '9')
		d = c - '0';
	else if(c >= 'a' && c <= 'z')
		d = c - 'a' + 10;
	else if(c >= 'A' && c <= 'Z')
		d = c - 'A' + 10;
	else
		return -1;
	return d < base ? d : -1;
}

static char*
skipspace(char *s)
{
	while(*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')
		s++;
	return s;
}

long
strtol(char *s, char **e, int base)
{
	char *p;
	ulong v, limit, hi;
	int d, neg, any, over;

	p = skipspace(s);
	neg = 0;
	if(*p == '-'){
		neg = 1;
		p++;
	}else if(*p == '+')
		p++;
	if(base == 0){
		base = 10;
		if(p[0] == '0' && (p[1] == 'x' || p[1] == 'X')){
			base = 16;
			p += 2;
		}else if(p[0] == '0')
			base = 8;
	}else if(base == 16 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X'))
		p += 2;

	hi = ~(ulong)0 >> 1;		/* LONG_MAX */
	limit = neg ? hi + 1 : hi;	/* |LONG_MIN| is one larger */
	v = 0;
	any = 0;
	over = 0;
	while((d = digit(*p, base)) >= 0){
		if(v > (limit - (ulong)d)/base)
			over = 1;
		else
			v = v*base + (ulong)d;
		any = 1;
		p++;
	}
	if(e != nil)
		*e = any ? p : s;
	if(over || v > limit)
		v = limit;
	if(neg){
		if(v == hi + 1)
			return -(long)hi - 1;	/* LONG_MIN */
		return -(long)v;
	}
	return (long)v;
}

ulong
strtoul(char *s, char **e, int base)
{
	char *p;
	ulong v, max;
	int d, any, neg, over;

	p = skipspace(s);
	neg = 0;
	if(*p == '-')
		neg = 1;
	if(*p == '-' || *p == '+')
		p++;
	if(base == 0){
		base = 10;
		if(p[0] == '0' && (p[1] == 'x' || p[1] == 'X')){
			base = 16;
			p += 2;
		}else if(p[0] == '0')
			base = 8;
	}else if(base == 16 && p[0] == '0' && (p[1] == 'x' || p[1] == 'X'))
		p += 2;

	max = ~(ulong)0;
	v = 0;
	any = 0;
	over = 0;
	while((d = digit(*p, base)) >= 0){
		if(v > (max - (ulong)d)/base)
			over = 1;
		else
			v = v*base + (ulong)d;
		any = 1;
		p++;
	}
	if(e != nil)
		*e = any ? p : s;
	if(over)
		return max;
	/*
	 * C negates the result modulo 2^64; keep that, since imported code
	 * written against strtoul may rely on it ("-1" is ULONG_MAX).
	 */
	return neg ? -v : v;
}

/*
 * abs() and labs(): os/port/devprog.c formats a signed offset with
 * abs(), and cannot use the int form of a value that is a long.
 */
int
abs(int v)
{
	return v < 0 ? -v : v;
}

long
labs(long v)
{
	return v < 0 ? -v : v;
}

/*
 * abort() is libc's "this cannot happen".  In a kernel the only honest
 * answer is the panic path; libinterp/gc.c and validstk.c reach it only
 * when the interpreter's own invariants are broken.
 */
void
abort(void)
{
	panic("abort");
}
