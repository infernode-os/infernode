/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Android x86_64 version.  Bionic always provides pthreads on Android,
 * so we don't carry the no-pthreads stack-pointer asm path that
 * Linux/amd64/include/emu.h has — getup() is always external (from
 * emu/Linux/os-Linux-pthreads.c at link time).
 */

extern Proc *getup(void);
#define	up	(getup())

/*
 * Stub FPU state.  emu/Android/asm-amd64.S's FPsave / FPrestore are
 * no-ops (Bionic + the host kernel save FP context on thread switch),
 * so we DO NOT need the 16-byte alignment that FXSAVE would require.
 *
 * Why this matters: Osenv embeds an FPU.  newprog (emu/port/dis.c)
 * places each new Osenv at `(uchar*)n + sizeof(Prog)` inside a single
 * malloc — when FPU asked for aligned(16), the C standard required
 * Osenv to be 16-aligned too.  sizeof(Prog) is not a multiple of 16
 * in our build, so the resulting Osenv* was misaligned on x86_64;
 * Clang inlined the memmove at dis.c:183 with MOVAPS / MOVDQA
 * (aligned SIMD moves), which faulted on the first new process →
 * SIGSEGV at newprog+725 during SDL_main boot in the APK.  Match
 * arm64's stub layout (see Android/arm64/include/emu.h) and the
 * problem goes away.
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[32];	/* placeholder — Bionic handles FP state */
};

#define KSTACK (32 * 1024)

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
