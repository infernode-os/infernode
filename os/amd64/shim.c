/*
 * os/amd64/shim.c -- the few kernel-library pieces proc.c reaches for
 * that are not ported yet.
 *
 * Each is the real thing at this kernel's scale: print and panic format
 * the verbs the kernel's own messages use (the full Plan 9 fmt arrives
 * with libkern), kstrdup allocates, incref/decref are atomic.  The VM is
 * a placeholder for the Dis interpreter: newproc records it, nothing
 * runs against it yet.  The /prog registry, the stack unwinder and the
 * debug keys are absent rather than wrong.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include <interp.h>

struct Vm vm0;

void
addprog(Proc *p)
{
	USED(p);
}

/* only reached when the Proc arena is exhausted; say so and stop */
void
resrcwait(char *reason)
{
	panic("out of resource: %s", reason);
}

void
kstrdup(char **p, char *s)
{
	char *t;
	ulong n;

	n = strlen(s) + 1;
	t = malloc(n);
	if(t == nil)
		panic("kstrdup");
	memmove(t, s, n);
	free(*p);
	*p = t;
}

int
incref(Ref *r)
{
	return __atomic_add_fetch(&r->ref, 1, __ATOMIC_SEQ_CST);
}

int
decref(Ref *r)
{
	int x;

	x = __atomic_sub_fetch(&r->ref, 1, __ATOMIC_SEQ_CST);
	if(x < 0)
		panic("decref");
	return x;
}

/*
 * A small formatter behind print and snprint, with a sink so the same
 * parser writes to the console or to a buffer.  Verbs: %s %c %d %ld
 * %lud %x %lx %lux %p %#x %#p %%.  Anything else prints literally, which
 * is a visible bug rather than a silent one.
 */
static int	outn;
static char	*snbuf;
static int	snlen;
static int	snmax;

static void
outc(int c)
{
	consputc(c);
	outn++;
}

static void
snc(int c)
{
	if(snlen < snmax - 1)
		snbuf[snlen++] = c;
}

static void	(*emit)(int) = outc;

static void
xdigits(uvlong v)
{
	static char dig[] = "0123456789abcdef";
	int i;

	for(i = 60; i >= 0; i -= 4)
		emit(dig[(v >> i) & 15]);
}

static void
vfmt(char *fmt, va_list ap)
{
	char *s;
	vlong sv;
	uvlong v;
	int c, lng;

	for(; *fmt != '\0'; fmt++){
		if(*fmt != '%'){
			emit(*fmt);
			continue;
		}
		fmt++;
		if(*fmt == '%'){
			emit('%');
			continue;
		}
		c = 0;
		if(*fmt == '#'){
			c = '#';
			fmt++;
		}
		lng = 0;
		while(*fmt == 'l'){
			lng++;
			fmt++;
		}
		if(*fmt == 'u' && (fmt[1] == 'd' || fmt[1] == 'x'))
			fmt++;
		switch(*fmt){
		case 'c':
			emit(va_arg(ap, int));
			break;
		case 's':
			s = va_arg(ap, char*);
			if(s == nil)
				s = "(nil)";
			while(*s != 0)
				emit(*s++);
			break;
		case 'd':
			sv = lng ? (vlong)va_arg(ap, long) : (vlong)va_arg(ap, int);
			if(sv < 0){
				emit('-');
				sv = -sv;
			}
			{
				char b[24];
				int i;

				i = 0;
				do {
					b[i++] = '0' + sv % 10;
					sv /= 10;
				} while(sv != 0);
				while(i > 0)
					emit(b[--i]);
			}
			break;
		case 'x':
			v = lng ? (uvlong)va_arg(ap, ulong) : (uvlong)va_arg(ap, uint);
			if(c == '#')
				emit('0');
			if(c == '#')
				emit('x');
			xdigits(v);
			break;
		case 'p':
			v = (uvlong)(uintptr)va_arg(ap, void*);
			if(c == '#')
				emit('0');
			if(c == '#')
				emit('x');
			xdigits(v);
			break;
		default:
			emit('%');
			if(c)
				emit(c);
			if(*fmt != '\0')
				emit(*fmt);
			break;
		}
	}
}

int
print(char *fmt, ...)
{
	va_list ap;

	emit = outc;
	outn = 0;
	va_start(ap, fmt);
	vfmt(fmt, ap);
	va_end(ap);
	return outn;
}

int
vsnprint(char *buf, int n, char *fmt, va_list ap)
{
	emit = snc;
	snbuf = buf;
	snlen = 0;
	snmax = n;
	vfmt(fmt, ap);
	buf[snlen] = 0;
	return snlen;
}

int
snprint(char *buf, int n, char *fmt, ...)
{
	va_list ap;
	int r;

	va_start(ap, fmt);
	r = vsnprint(buf, n, fmt, ap);
	va_end(ap);
	return r;
}

void
putstrn(char *s, int n)
{
	while(n-- > 0)
		consputc(*s++);
}

void
panic(char *fmt, ...)
{
	va_list ap;

	emit = outc;
	consprint("infernode/amd64: panic: ");
	va_start(ap, fmt);
	vfmt(fmt, ap);
	va_end(ap);
	consprint("\n");
	conshalt();
}

/* the kernel features this stage does not have */
void
debugkey(Rune c, char *s, void (*f)(void), int x)
{
	USED(c);
	USED(s);
	USED(f);
	USED(x);
}

void
dumpstack(void)
{
}

void
labelstack(Proc *p)
{
	USED(p);
}

void
ixsummary(void)
{
}

Prog*
currun(void)
{
	return nil;
}

int
iprogpid(void *iprog)
{
	USED(iprog);
	return -1;
}

int
upkilled(void)
{
	return 0;
}

void
closeegrp(Egrp *g)
{
	USED(g);
}

void
closefgrp(Fgrp *g)
{
	USED(g);
}

void
closepgrp(Pgrp *g)
{
	USED(g);
}

void
closesigs(Skeyset *k)
{
	USED(k);
}

void
splxpc(int s)
{
	splx(s);
}

/*
 * A rough microsecond wait.  Nothing that needs a calibrated clock has
 * called it yet; the PIT arrives with portclock.c.
 */
void
microdelay(int us)
{
	volatile int i;

	for(; us > 0; us--)
		for(i = 0; i < 100; i++)
			__asm__ volatile("pause");
}

void
kstrcpy(char *s, char *t, int ns)
{
	int nt;

	if(s == nil || t == nil || ns <= 0)
		return;
	nt = strlen(t);
	if(nt >= ns)
		nt = ns - 1;
	memmove(s, t, nt);
	s[nt] = 0;
}

char*
strcpy(char *s, char *t)
{
	char *r;

	r = s;
	while((*s++ = *t++) != 0)
		;
	return r;
}
