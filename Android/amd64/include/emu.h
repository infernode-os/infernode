/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Android x86_64 version. Bionic always provides pthreads on Android,
 * so we don't carry the no-pthreads stack-pointer asm path that
 * Linux/amd64/include/emu.h has — getup() is always external (from
 * emu/Linux/os-Linux-pthreads.c at link time). The FPU save area
 * matches x86_64 FXSAVE: 512 bytes, 16-byte aligned.
 */

extern Proc *getup(void);
#define	up	(getup())

/*
 * This structure must agree with FPsave and FPrestore asm routines.
 * x86_64 FP/SSE state is 512 bytes (FXSAVE area); requires 16-byte alignment.
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[512] __attribute__((aligned(16)));
} __attribute__((aligned(16)));

#define KSTACK (32 * 1024)

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
