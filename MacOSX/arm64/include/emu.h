/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * arm64 macOS version
 */

/*
 * The current process, in a thread-local variable: up is read on every
 * lock and unlock (and so every heap allocation) and every waserror, and
 * a call to pthread_getspecific each time was a sixth of the CPU a Limbo
 * program allocating hard spent.  os.c sets it wherever it sets the
 * thread's key.
 */
extern __thread Proc *machup;
extern Proc *getup(void);
#define	up	machup

/*
 * This structure must agree with FPsave and FPrestore asm routines
 * arm64 uses NEON/FP registers but macOS handles context switching
 * so we use a minimal stub structure
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[32];	/* placeholder - arm64 FP state handled by OS */
};

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
