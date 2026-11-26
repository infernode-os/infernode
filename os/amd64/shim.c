/*
 * os/amd64/shim.c -- the kernel-library pieces the port still reaches
 * for from files that are not linked yet.
 *
 * Most of what used to be here has been replaced by the real thing:
 * kstrdup, kstrcpy, incref/decref came with chan.c; resrcwait and
 * closesigs with pgrp.c; ixsummary with qio.c.  What remains is the Dis
 * VM's placeholder, the stack unwinder, the debug keys, and a few small
 * adapters.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include <interp.h>

struct Vm vm0;

/* the host owner, until devcons defines it: stat strings need a name */
char *eve = "inferno";

/* the kernel's build date, which dev.c records as a file's mtime */
ulong kerndate;

void
addprog(Proc *p)
{
	USED(p);
}

/* the /prog registry and VM queries have no answers until dis.c */
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

/*
 * print and panic go through the same formatter as snprint: libkern's
 * vseprint, which dev.c's device layer links anyway.
 */
int
print(char *fmt, ...)
{
	va_list ap;
	char buf[PRINTSIZE];
	int n;

	va_start(ap, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, ap) - buf;
	va_end(ap);
	putstrn(buf, n);
	return n;
}

/* iprint: the same, but callable at high spl; the console is polled */
int
iprint(char *fmt, ...)
{
	va_list ap;
	char buf[PRINTSIZE];
	int n;

	va_start(ap, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, ap) - buf;
	va_end(ap);
	putstrn(buf, n);
	return n;
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
	char buf[PRINTSIZE];
	int n;

	consprint("infernode/amd64: panic: ");
	va_start(ap, fmt);
	n = vseprint(buf, buf+sizeof(buf), fmt, ap) - buf;
	va_end(ap);
	putstrn(buf, n);
	consprint("\n");
	conshalt();
}

void
_assert(char *s)
{
	panic("assertion failed: %s", s);
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
closeegrp(Egrp *g)
{
	USED(g);
}

/* the time(2)-style seconds devdir records */
long
seconds(void)
{
	return (long)(todget(nil) / 1000000000LL);
}

/* the 9P client's mount teardown, which has no mounts to tear down yet */
void
muxclose(Mnt *m)
{
	USED(m);
}

void
splxpc(int s)
{
	splx(s);
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
