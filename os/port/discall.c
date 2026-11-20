#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include <isa.h>
#include <interp.h>
#include "kernel.h"

#define	QP(l)	(Prog**)((char*)(l)+sizeof(QLock))

void*
libqlowner(void *l)
{
	return *QP(l);
}

void
libqlock(void *l)
{
	Prog *p;
	QLock *q;

	q = l;
	p = currun();
	if(p == nil)
		panic("libqlock");

	if(!canqlock(q)) {
		release();
		qlock(q);
		acquire();
	}
	*QP(l) = p;
}

void
libqunlock(void *l)
{
	Prog *p;
	QLock *q;

	q = l;
	p = currun();
	if(p == nil)
		panic("libqunlock 1");
	if(*QP(l) != p)
		panic("libqunlock 2");

	*QP(l) = nil;
	qunlock(q);
}

/*
 * The same lock, owned by the process rather than by a Prog: for a
 * caller that holds an interpreter but has no Prog running in it --
 * vmrun loading a command into a VM that has none yet (#944). It does
 * not let the interpreter go while it waits: whoever holds the lock is
 * compiling in another VM and needs nothing of this one's to finish.
 */
void
libqlockproc(void *l)
{
	qlock((QLock*)l);
	*QP(l) = nil;
}

void
libqunlockproc(void *l)
{
	if(*QP(l) != nil)
		panic("libqunlockproc");
	qunlock((QLock*)l);
}

/*
 * compile() under the lock, and the lock let go if the code generator
 * raises, which it does for an instruction it does not know. With no
 * way out the lock stayed held: the next module to be compiled waited
 * for it, holding its VM as libqlockproc is meant to, and no Limbo
 * program ran again. One .dis file with one bad opcode, loaded by
 * anyone.
 *
 * The 64-bit code generators are told too, before the lock goes: what
 * a compile had allocated when it raised stayed allocated (megabytes
 * for each such load), and two of them were left believing a compile
 * was still under way, which the next one panicked on.
 */
int
libcompile(void *l, Module *m, int size)
{
	int ok;

	libqlockproc(l);
	if(waserror()){
#if defined(__aarch64__) || defined(__x86_64__) || defined(_M_X64) || (defined(__riscv) && __riscv_xlen == 64)
		compileabort();		/* comp-amd64.c, comp-arm64.c, comp-riscv64.c */
#endif
		libqunlockproc(l);
		nexterror();
	}
	ok = compile(m, size, nil);
	poperror();
	libqunlockproc(l);
	return ok;
}

/*
 * parsemod() with what it has made given back if it raises: the module
 * being built, and the caller's copy of the file and its Dir (readmod's,
 * which has no label to free them with).  It raises when the Dis heap
 * cannot hold the module's data, and when the code generator does.
 */
Module*
libparsemod(char *path, uchar *code, ulong length, Dir *dir)
{
	Module *volatile building;
	Module *m;

	building = nil;
	if(waserror()){
		if(building != nil)
			parsefail(building);
		free(code);
		free(dir);
		nexterror();
	}
	m = parsemod(path, code, length, dir, &building);
	poperror();
	return m;
}

void*
libqlalloc(void)
{
	QLock *q;

	q = mallocz(sizeof(QLock)+sizeof(Prog*), 1);
	return q;
}

void
libqlfree(void *l)
{
	free(l);
}

vlong
libseek(int fd, vlong off, int whence)
{
	release();
	off = kseek(fd, off, whence);
	acquire();
	return off;
}

int
libread(int fd, void *buf, int n)
{
	release();
	n = kread(fd, buf, n);
	acquire();
	return n;
}

int
libreadn(int fd, void *av, long n)
{
	char *a;
	long m, t;

	a = av;
	t = 0;
	release();
	while(t < n){
		m = kread(fd, a+t, n-t);
		if(m <= 0){
			if(t == 0){
				acquire();
				return m;
			}
			break;
		}
		t += m;
	}
	acquire();
	return t;
}

int
libwrite(int fd, void *buf, int n)
{
	release();
	n = kwrite(fd, buf, n);
	acquire();
	return n;
}

int
libopen(char *name, int omode)
{
	int fd;

	release();
	fd = kopen(name, omode);
	acquire();
	return fd;
}

int
libclose(int fd)
{
	release();
	fd = kclose(fd);
	acquire();
	return fd;
}

Dir*
libdirfstat(int fd)
{
	Dir *d;

	release();
	d = kdirfstat(fd);
	acquire();
	return d;
}

int
libbind(char *s, char *t, int f)
{
	int n;

	release();
	n = kbind(s, t, f);
	acquire();
	return n;
}

void
libchanclose(void *chan)
{
	release();
	cclose(chan);
	acquire();
}

void*
libfdtochan(int fd, int mode)
{
	Chan *c;

	release();
	if(waserror()) {
		acquire();
		return nil;
	}
	c = fdtochan(up->env->fgrp, fd, mode, 0, 1);
	poperror();
	acquire();
	return c;
}
