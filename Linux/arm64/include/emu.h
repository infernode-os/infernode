/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Linux arm64 version
 */

/*
 * The current process, in a thread-local variable: up is read on every
 * lock and unlock (and so every heap allocation) and every waserror, and
 * a call to pthread_getspecific each time was a sixth of the CPU a Limbo
 * program allocating hard spent.  kproc-pthreads.c sets it wherever it
 * sets the thread's key.
 */
extern Proc *getup(void);
#ifdef __ANDROID__
/*
 * Not on Android: its compilers make __thread emulated below API 29
 * (Termux's is 24), a lookup that can allocate on a thread's first
 * use, and up is read in signal handlers and with locks held.  With it,
 * the Termux emulator printed nothing at boot.
 */
#define	up	(getup())
#else
extern __thread Proc *machup;
#define	up	machup
#endif

/*
 * This structure must agree with FPsave and FPrestore asm routines
 * arm64 uses NEON/FP registers - Linux handles context switching
 * so we use a minimal stub structure
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[32];	/* placeholder - arm64 FP state handled by OS */
};

#define KSTACK (32 * 1024)

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
