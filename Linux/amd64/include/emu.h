/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Linux x86_64 (amd64) version
 */

/*
 * This structure must agree with FPsave and FPrestore asm routines
 * x86_64 has larger FP/SSE state than 32-bit
 * fxsave/fxrstor require 16-byte alignment
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[512] __attribute__((aligned(16)));	/* x86_64 FXSAVE area is 512 bytes */
} __attribute__((aligned(16)));

#define KSTACK (32 * 1024)

/*
 * When using pthreads, getup() is provided externally
 */
#ifndef USE_PTHREADS
static __inline Proc *getup(void) {
	Proc *p;
	__asm__(	"movq	%%rsp, %%rax\n\t"
			: "=a" (p)
	);
	return *(Proc **)((uintptr)p & ~(KSTACK - 1));
}
#define	up	(getup())
#else
/*
 * The current process, in a thread-local variable: up is read on every
 * lock and unlock (and so every heap allocation) and every waserror, and
 * a call to pthread_getspecific each time was a sixth of the CPU a Limbo
 * program allocating hard spent.  kproc-pthreads.c sets it wherever it
 * sets the thread's key.
 */
extern	__thread Proc *machup;
extern	Proc*	getup(void);
#define	up	machup
#endif

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
