#include	<sys/types.h>
#include	<time.h>
#include	<termios.h>
#include	<sys/ucontext.h>
#include	<signal.h>
#include 	<pwd.h>
#include	<sched.h>
#include	<sys/resource.h>
#include	<sys/wait.h>
#include	<sys/time.h>

#include	<stdint.h>

#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include <fpuctl.h>

#include <semaphore.h>
#include <pthread.h>

#include	<raise.h>

/* glibc 2.3.3-NTPL messes up getpid() by trying to cache the result, so we'll do it ourselves */
#include	<sys/syscall.h>
#define	getpid()	syscall(SYS_getpid)

enum
{
	DELETE	= 0x7f,
	CTRLC	= 'C'-'@',
	NSTACKSPERALLOC = 16,
	X11STACK=	256*1024
};
char *hosttype = "Linux";

typedef sem_t	Sem;

extern int dflag;

int	gidnobody = -1;
int	uidnobody = -1;
static struct 	termios tinit;

static void
sysfault(char *what, void *addr)
{
	char buf[64];

	snprint(buf, sizeof(buf), "sys: %s%#p", what, addr);
	disfault(nil, buf);
}

static void
trapILL(int signo, siginfo_t *si, void *a)
{
	USED(signo);
	USED(a);
	sysfault("illegal instruction pc=", si->si_addr);
}

static int
isnilref(siginfo_t *si)
{
	return si != 0 && (si->si_addr == (void*)~(uintptr_t)0 || (uintptr_t)si->si_addr < 512);
}

/*
 * Report where a memory fault happened before handing it to disfault().
 *
 * A nil dereference from Limbo is an ordinary exception and needs no
 * commentary.  Anything else is an emulator bug, and the campaign that
 * motivated this (INFR-421) had to be re-run because all it left behind
 * was rc=-11: the ucontext was discarded here, so no PC, no symbol, no
 * faulting function.  The MacOSX port already prints this; keeping the
 * two in step means a Linux crash is diagnosable from its log alone,
 * whether or not a core was allowed.
 *
 * dladdr() is not async-signal-safe, strictly.  We are already on a
 * path that ends in disfault or death, the same trade the MacOSX
 * handler makes, and an unresolved PC is itself a finding: it means the
 * fault was in JIT-generated code.
 *
 * dladdr and REG_RIP live behind _GNU_SOURCE, which cannot be set here:
 * it makes features.h force _XOPEN_SOURCE to 700 and lib9.h then
 * redefines it to 500, warning on every build.  Declare the two pieces
 * we need instead.  REG_RIP/REG_EIP are fixed by the x86 psABI.
 */
typedef struct {
	const char	*dli_fname;
	void		*dli_fbase;
	const char	*dli_sname;
	void		*dli_saddr;
} Dlinfo;

extern int dladdr(const void*, Dlinfo*);

enum {
	Gregrip	= 16,	/* REG_RIP */
	Gregeip	= 14,	/* REG_EIP */
};

static void
faultwhere(void *a)
{
	ucontext_t *uc;
	Dlinfo di;
	void *pc;

	if(a == nil)
		return;
	uc = (ucontext_t*)a;
#if defined(__x86_64__)
	pc = (void*)uc->uc_mcontext.gregs[Gregrip];
#elif defined(__i386__)
	pc = (void*)uc->uc_mcontext.gregs[Gregeip];
#elif defined(__aarch64__)
	pc = (void*)uc->uc_mcontext.pc;
#else
	USED(uc);
	return;
#endif
	fprint(2, "  PC=%p\n", pc);
	if(dladdr(pc, &di) && di.dli_sname != nil)
		fprint(2, "  PC in %s+%#lx\n", di.dli_sname,
			(ulong)((uintptr)pc - (uintptr)di.dli_saddr));
	else
		fprint(2, "  PC not in any image (JIT-generated code?)\n");
	if(up != nil && up->nlocks > 0)
		fprint(2, "  holding %d lock(s)\n", up->nlocks);
}

static void
trapmemref(int signo, siginfo_t *si, void *a)
{
	if(isnilref(si))
		disfault(nil, exNilref);
	else if(signo == SIGBUS){
		fprint(2, "BUS: addr=%p code=%d\n", si->si_addr, si->si_code);
		faultwhere(a);
		sysfault("bad address addr=", si->si_addr);	/* eg, misaligned */
	}else{
		fprint(2, "SEGV: addr=%p code=%d\n", si->si_addr, si->si_code);
		faultwhere(a);
		sysfault("segmentation violation addr=", si->si_addr);
	}
}

static void
trapFPE(int signo, siginfo_t *si, void *a)
{
	char buf[64];

	USED(signo);
	USED(a);
	snprint(buf, sizeof(buf), "sys: fp: exception status=%.4lux pc=%#p", getfsr(), si->si_addr);
	disfault(nil, buf);
}

static void
trapUSR1(int signo)
{
	int intwait;

	USED(signo);

	intwait = up->intwait;
	up->intwait = 0;	/* clear it to let proc continue in osleave */

	if(up->type != Interp)		/* Used to unblock pending I/O */
		return;

	if(intwait == 0)		/* Not posted so it's a sync error */
		disfault(nil, Eintr);	/* Should never happen */
}

void
oslongjmp(void *regs, osjmpbuf env, int val)
{
	USED(regs);
	siglongjmp(env, val);
}

static void
termset(void)
{
	struct termios t;

	tcgetattr(0, &t);
	tinit = t;
	t.c_lflag &= ~(ICANON|ECHO|ISIG);
	t.c_cc[VMIN] = 1;
	t.c_cc[VTIME] = 0;
	tcsetattr(0, TCSANOW, &t);
}

static void
termrestore(void)
{
	tcsetattr(0, TCSANOW, &tinit);
}

void
cleanexit(int x)
{
	USED(x);

	if(up->intwait) {
		up->intwait = 0;
		return;
	}

	if(dflag == 0)
		termrestore();

	kill(0, SIGKILL);
	exit(0);
}

void
osreboot(char *file, char **argv)
{
	if(dflag == 0)
		termrestore();
	execvp(file, argv);
	error("reboot failure");
}

#ifdef GUI_SDL3
/*
 * Worker thread wrapper for emuinit when using SDL3 GUI.
 * The main thread must remain free for sdl3_mainloop().
 */
static void*
emuinit_worker(void *arg)
{
	char *imod = (char*)arg;
	Proc *p;

	/* Create Proc for this worker thread */
	p = newproc();
	kprocsetup(p);

	/* Now emuinit can use 'up' */
	emuinit(imod);

	return NULL;  /* Never reached - emuinit never returns */
}
#endif

void
libinit(char *imod)
{
	struct sigaction act;
	struct passwd *pw;
	Proc *p;
	char sys[64];

	setsid();

	gethostname(sys, sizeof(sys));
	kstrdup(&ossysname, sys);
	pw = getpwnam("nobody");
	if(pw != nil) {
		uidnobody = pw->pw_uid;
		gidnobody = pw->pw_gid;
	}

	if(dflag == 0)
		termset();

	memset(&act, 0, sizeof(act));
	act.sa_handler = trapUSR1;
	sigaction(SIGUSR1, &act, nil);

	act.sa_handler = SIG_IGN;
	sigaction(SIGCHLD, &act, nil);

	/*
	 * For the correct functioning of devcmd in the
	 * face of exiting slaves
	 */
	signal(SIGPIPE, SIG_IGN);
	if(signal(SIGTERM, SIG_IGN) != SIG_IGN)
		signal(SIGTERM, cleanexit);
	if(signal(SIGINT, SIG_IGN) != SIG_IGN)
		signal(SIGINT, cleanexit);

	if(sflag == 0) {
		act.sa_flags = SA_SIGINFO;
		act.sa_sigaction = trapILL;
		sigaction(SIGILL, &act, nil);
		act.sa_sigaction = trapFPE;
		sigaction(SIGFPE, &act, nil);
		act.sa_sigaction = trapmemref;
		sigaction(SIGBUS, &act, nil);
		sigaction(SIGSEGV, &act, nil);
		act.sa_flags &= ~SA_SIGINFO;
	}

	p = newproc();
	kprocinit(p);

	pw = getpwuid(getuid());
	if(pw != nil)
		kstrdup(&eve, pw->pw_name);
	else
		print("cannot getpwuid\n");

	p->env->uid = getuid();
	p->env->gid = getgid();

#ifdef GUI_SDL3
	/* SDL3: Spawn emuinit on worker thread so main thread can run sdl3_mainloop() */
	{
		pthread_t worker_thread;

		if(pthread_create(&worker_thread, NULL, emuinit_worker, imod) != 0)
			panic("libinit: pthread_create failed for emuinit worker");

		pthread_detach(worker_thread);

		/* Give worker thread a moment to start */
		usleep(50000);  /* 50ms */
	}
	/* Return to main() which will call sdl3_mainloop() */
#else
	/* Headless: Run emuinit on main thread (never returns) */
	emuinit(imod);
#endif
}

int
readkbd(void)
{
	int n;
	char buf[1];

	n = read(0, buf, sizeof(buf));
	if(n < 0)
		print("keyboard close (n=%d, %s)\n", n, strerror(errno));
	if(n <= 0) {
		qhangup(kbdq, nil);
		pexit("keyboard thread", 0);
	}

	switch(buf[0]) {
	case '\r':
		buf[0] = '\n';
		break;
	case DELETE:
		buf[0] = 'H' - '@';
		break;
	case CTRLC:
		cleanexit(0);
		break;
	}
	return buf[0];
}

/*
 * Return an abitrary millisecond clock time
 */
long
osmillisec(void)
{
	static long sec0 = 0, usec0;
	struct timeval t;

	if(gettimeofday(&t,(struct timezone*)0)<0)
		return 0;

	if(sec0 == 0) {
		sec0 = t.tv_sec;
		usec0 = t.tv_usec;
	}
	return (t.tv_sec-sec0)*1000+(t.tv_usec-usec0+500)/1000;
}

/*
 * Return the time since the epoch in nanoseconds and microseconds
 * The epoch is defined at 1 Jan 1970
 */
vlong
osnsec(void)
{
	struct timeval t;

	gettimeofday(&t, nil);
	return (vlong)t.tv_sec*1000000000L + t.tv_usec*1000;
}

vlong
osusectime(void)
{
	struct timeval t;
 
	gettimeofday(&t, nil);
	return (vlong)t.tv_sec * 1000000 + t.tv_usec;
}

int
osmillisleep(ulong milsec)
{
	struct  timespec time;

	time.tv_sec = milsec/1000;
	time.tv_nsec= (milsec%1000)*1000000;
	nanosleep(&time, NULL);
	return 0;
}

int
limbosleep(ulong milsec)
{
	return osmillisleep(milsec);
}
