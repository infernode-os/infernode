/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * amd64 (x86_64) macOS version
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
 * macOS saves the SSE/x87 state across thread switches itself,
 * so FPsave and FPrestore are stubs and this is only a placeholder.
 * No aligned(16): FPU sits in Osenv, the alignment spread to it, and
 * clang then stored to Osenv with movaps, which faults on an Intel CPU
 * (not under Rosetta) because the pool allocator aligns only to 8.
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[32];	/* placeholder - the OS keeps the FP state */
};

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
