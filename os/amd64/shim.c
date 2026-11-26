/*
 * os/amd64/shim.c -- the kernel-library pieces the port still reaches
 * for from files that are not linked yet.
 *
 * Most of what used to be here has been replaced by the real thing:
 * kstrdup, kstrcpy, incref/decref came with chan.c; resrcwait and
 * closesigs with pgrp.c; ixsummary with qio.c.  What remains is the
 * stack unwinder, the debug keys, the board's reset and a few small
 * adapters.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include <interp.h>

/* the kernel's build date, which dev.c records as a file's mtime */
ulong kerndate;

/*
 * modinit -- register the built-in Dis modules.  Upstream's native
 * kernels generate this from the "mod" section of the kernel
 * configuration (os/port/mkdevc); this port has no mkdevc yet, and
 * links exactly two:
 *
 *   $Sys   what a Limbo program calls to open, read, write, sleep
 *   $Math  sin, cos, sqrt and the rest, plus the %g/%e/%f format verbs
 *
 * $Draw and $Tk need the draw device and the widget library; $Keyring
 * needs the crypto stack.  Both are separate stages.
 */
extern void sysmodinit(void);
extern void mathmodinit(void);

void
modinit(void)
{
	sysmodinit();
	mathmodinit();
}

void
dumpstack(void)
{
}

/* the board's "booted" watchdog release; there is no watchdog here */
void
booted(void)
{
}

/*
 * The console device reaches for a few things this stage does not have:
 * the board's reset, the software screen's debug keys, the Dis VM's
 * user renaming and heap audit, and a randomness source.
 *
 * genrandom PANICS rather than filling a buffer with something weak: a
 * key that looks random and is not is worse than a kernel that says it
 * has no generator.  randomread returns no bytes and randominit is
 * quiet; nothing in this stage asks for them.
 */
void
reboot(void)
{
	conshalt();
}

void
halt(void)
{
	conshalt();
}

void
tryboot(void)
{
	conshalt();
}

void
uartputs(char *s, int n)
{
	conswrite(s, n);
}

void
screendumpkey(void)
{
}

void
screenhexkey(void)
{
}

void
randominit(void)
{
}

ulong
randomread(void *p, ulong n)
{
	USED(p);
	USED(n);
	return 0;
}

void
genrandom(uchar *p, int n)
{
	USED(p);
	USED(n);
	panic("genrandom: this kernel has no random generator");
}

/* no hardware generator: say so rather than invent bytes */
void
rngassessopen(void)
{
}

long
hwrandomread(void *p, long n)
{
	USED(p);
	USED(n);
	return -1;
}

long
hwrandombootread(void *p, long n, vlong t)
{
	USED(p);
	USED(n);
	USED(t);
	return -1;
}

void
labelstack(Proc *p)
{
	USED(p);
}

void
splxpc(int s)
{
	splx(s);
}

char*
strdup(char *s)
{
	char *t;

	t = malloc(strlen(s)+1);
	if(t != nil)
		strcpy(t, s);
	return t;
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
