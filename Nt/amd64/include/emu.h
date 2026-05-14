/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * Windows AMD64 version.
 * On x86_64, FP context is handled per-thread by the OS.
 * FPsave/FPrestore are no-ops (implemented in asm-amd64-win.asm).
 */

typedef	struct	FPU	FPU;
struct FPU
{
	uchar	env[512];	/* FXSAVE area (512 bytes for x86_64) */
};

extern	void		sleep(int);

/* Set up private thread space */
extern	__declspec(thread) Proc*	up;
#define Sleep	NTsleep

typedef jmp_buf osjmpbuf;

/*
 * On Windows x64, the standard `longjmp` uses `RtlUnwind` to walk the
 * stack and run SEH __finally blocks / C++ destructors between the
 * longjmp call site and the matching `setjmp`. That walk reads the PE
 * function-table entry for every frame in between.
 *
 * Inferno's `error()` ultimately invokes `oslongjmp` → `longjmp`. With
 * the JIT enabled, there are JIT-compiled frames between the C-level
 * `setjmp` (in waserror) and the eventual `longjmp` — frames whose
 * unwind data RtlUnwind can't safely walk on recent ntdll builds
 * (10.0.26100+), producing STATUS_BAD_FUNCTION_TABLE (0xC00000FF).
 *
 * Disable the SEH walk by zeroing `_JUMP_BUFFER.Frame` after each
 * `setjmp` — the documented hook that tells `longjmp` "just restore
 * registers, don't unwind." Used by JITs like Mono and SpiderMonkey
 * on Windows. Safe because emu is plain C: there are no C++ object
 * destructions or SEH __finally blocks that need to run during the
 * jump.
 *
 * setjmp must remain a textual call at the user's call site (it's a
 * compiler intrinsic, can't be wrapped), so we pass its return value
 * through a helper that nulls the Frame field on the first-time
 * (zero-return) path and is a no-op on the longjmp return.
 */
static __forceinline int
ossetjmp_no_seh(int rv, void *buf)
{
	if(rv == 0)
		*(unsigned __int64*)buf = 0;	/* _JUMP_BUFFER.Frame is the first qword */
	return rv;
}
#define	ossetjmp(buf)	ossetjmp_no_seh(setjmp(buf), (buf))
