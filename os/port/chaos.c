/*
 * The chaos build: faults the kernel can meet but seldom does, made
 * often, to find the code that does not survive them.
 *
 * Built in only with -DCHAOS (EXTRACFLAGS=-DCHAOS to
 * tests/host/baremetal_test.sh); every hook below is then a rate, off
 * until set, through #c/chaos:
 *
 *	echo 'malloc 1000' > /dev/chaos		one malloc in 1000 fails
 *	echo 'off' > /dev/chaos			all off
 *	echo 'vms 0xe' > /dev/chaos		only in Dis VMs 1-3
 *	cat /dev/chaos				each site: its rate, how often it fired
 *
 * The sites:
 *
 *	malloc	malloc, mallocz and realloc return nil, as when the pool
 *		is exhausted (smalloc, which waits, is left alone)
 *	sleep	a sleep() of a Dis proc in a system call is interrupted,
 *		as when its Prog is killed: the call fails with Eintr
 *	lock	the holder of a spin lock dawdles before going on, a few
 *		microseconds, widening every window another core can
 *		reach into
 *	yield	a proc releasing a spin lock gives up its core, as when
 *		preempted there
 *
 * vms is a mask of the Dis VMs (#X) whose procs meet the faults, bit 0
 * VM 0; bit 31 is the kernel's own procs, in no VM. Sparing VM 0 keeps
 * the console's shell, and whatever drives the machine through it, out
 * of it. A rate is one in N; N of 0 is off. The random numbers are not good
 * ones, and the counters are not exact under contention: neither needs
 * to be.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include <interp.h>

#ifdef CHAOS

enum {
	Cmalloc,
	Csleep,
	Clock,
	Cyield,
	Nchaos
};

static char *chaosname[Nchaos] = {
	[Cmalloc]	"malloc",
	[Csleep]	"sleep",
	[Clock]	"lock",
	[Cyield]	"yield",
};

static ulong chaosrate[Nchaos];
static ulong chaoshits[Nchaos];
static ulong chaosseed = 0x9E3779B9;
static ulong chaosvms = ~0UL;

enum { Kernvm = 31 };

static int
chaos(int site)
{
	ulong r, x;

	r = chaosrate[site];
	if(r == 0)
		return 0;
	if(up != nil){
		if(up->vm != nil){
			if((chaosvms & (1UL << (up->vm->id & 31))) == 0)
				return 0;
		}else if((chaosvms & (1UL << Kernvm)) == 0)
			return 0;
	}
	x = chaosseed;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	x += m->machno;
	chaosseed = x;
	if(x % r != 0)
		return 0;
	chaoshits[site]++;
	return 1;
}

int
chaosmalloc(void)
{
	return chaos(Cmalloc);
}

/*
 * Only where an interrupt can come anyway: a Dis proc in a Prog's
 * system call (it has released the VM for it: iprog), with an error
 * label to take it to. A VM's kproc idling in vmachine has no Prog to
 * kill, and an Eintr there reaches its handler with none current.
 */
void
chaossleep(void)
{
	if(up == nil || up->type != Interp || up->iprog == nil || up->nerrlab == 0)
		return;
	if(chaos(Csleep))
		error(Eintr);
}

void
chaoslock(void)
{
	if(chaos(Clock))
		microdelay(1 + chaosseed % 20);
}

int
chaosyield(void)
{
	return chaos(Cyield);
}

long
chaosread(void *a, long n, vlong offset)
{
	char *buf, *p, *e;
	int i;

	buf = smalloc(READSTR);
	if(waserror()){
		free(buf);
		nexterror();
	}
	p = buf;
	e = buf + READSTR;
	for(i = 0; i < Nchaos; i++)
		p = seprint(p, e, "%s %lud %lud\n", chaosname[i], chaosrate[i], chaoshits[i]);
	p = seprint(p, e, "vms %#lux\n", chaosvms);
	n = readstr(offset, a, n, buf);
	poperror();
	free(buf);
	return n;
}

long
chaoswrite(void *a, long n)
{
	Cmdbuf *cb;
	int i;
	char *e;
	ulong r;

	cb = parsecmd(a, n);
	if(waserror()){
		free(cb);
		nexterror();
	}
	if(cb->nf == 1 && strcmp(cb->f[0], "off") == 0){
		for(i = 0; i < Nchaos; i++)
			chaosrate[i] = 0;
	}else if(cb->nf == 2 && strcmp(cb->f[0], "vms") == 0){
		r = strtoul(cb->f[1], &e, 0);
		if(*e != 0)
			error(Ebadarg);
		chaosvms = r;
	}else if(cb->nf == 2 && strcmp(cb->f[0], "seed") == 0){
		r = strtoul(cb->f[1], &e, 0);
		if(*e != 0)
			error(Ebadarg);
		chaosseed = r | 1;
	}else if(cb->nf == 2){
		for(i = 0; i < Nchaos; i++)
			if(strcmp(cb->f[0], chaosname[i]) == 0)
				break;
		if(i == Nchaos)
			error("unknown chaos site");
		r = strtoul(cb->f[1], &e, 0);
		if(*e != 0)
			error(Ebadarg);
		chaosrate[i] = r;
		chaoshits[i] = 0;
	}else
		error(Ebadarg);
	poperror();
	free(cb);
	return n;
}

#endif
