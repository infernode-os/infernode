/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Linux arm64 version
 */

extern Proc *getup(void);
#define	up	(getup())

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
