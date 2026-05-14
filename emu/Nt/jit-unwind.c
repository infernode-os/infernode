/*
 * emu/Nt/jit-unwind.c
 *
 * Register dynamic SEH unwind info for JIT-compiled code on Windows x64.
 *
 * Background
 * ----------
 * Windows x86-64 uses table-based SEH: every executable function must
 * have a RUNTIME_FUNCTION entry pointing at an UNWIND_INFO struct, so
 * the unwinder (RtlLookupFunctionEntry, walked during exception handling
 * and stack traces) can identify the function and how to undo its prolog.
 *
 * Statically linked code has these in the PE image's .pdata / .xdata.
 * Dynamically generated (JITted) code has neither. Without registration,
 * any unwind that crosses a JIT frame either silently misbehaves
 * (older ntdll) or raises STATUS_BAD_FUNCTION_TABLE (0xC00000FF) on
 * recent Windows builds (10.0.26100+).
 *
 * What we do
 * ----------
 * Each JIT region passed to jit_unwind_register() is registered via
 * RtlInstallFunctionTableCallback. When Windows needs unwind info for
 * a PC inside the region, it calls our callback, which hands back a
 * pre-computed RUNTIME_FUNCTION whose UnwindData points at an UNWIND_INFO
 * stored in the FIRST 16 BYTES of the region.
 *
 * The UNWIND_INFO declares the JIT code as a "leaf function": no prolog,
 * no callee-saved registers, no stack frame, no unwind codes. Windows
 * treats it as nothing-to-unwind and continues past it.
 *
 * Layout of a registered JIT region
 * ----------------------------------
 *   offset 0..3   : UNWIND_INFO (Version=1, Flags=0, SizeOfProlog=0,
 *                   CountOfCodes=0, FrameRegister=0, FrameOffset=0).
 *   offset 4..15  : padding for alignment.
 *   offset 16..end: JIT code (this is what the caller of jitmalloc sees).
 *
 * Callers of jitmalloc() get a pointer past the 16-byte header, so they
 * never see or write to the unwind data area.
 *
 * References
 * ----------
 * Microsoft Learn: "Exception Handling (x64)" — RUNTIME_FUNCTION,
 * UNWIND_INFO, RtlInstallFunctionTableCallback contracts.
 *
 * V8: src/diagnostics/unwinding-info-win64.cc — production reference
 * for dynamic unwind registration in a JIT.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winnt.h>
#include <stdio.h>

#include "jit-unwind.h"

/* Set INFERNODE_JIT_UNWIND_TRACE=1 in the environment to log each
 * registration/unregistration to stderr. Off by default. */
static int trace_initialised = 0;
static int trace_enabled = 0;
static int
trace(void)
{
	if(!trace_initialised) {
		char buf[8];
		DWORD n = GetEnvironmentVariableA("INFERNODE_JIT_UNWIND_TRACE", buf, sizeof(buf));
		trace_enabled = (n > 0 && buf[0] != '0');
		trace_initialised = 1;
	}
	return trace_enabled;
}

/*
 * STATUS — 2026-05-14
 *
 * The framework is correct in shape: all 20 JIT regions register
 * successfully via RtlInstallFunctionTableCallback, and we hand back
 * either a COMVEC_FRAME (6 PUSH_NONVOL) or LEAF UNWIND_INFO depending
 * on caller kind. However the production crash still reproduces with
 * STATUS_BAD_FUNCTION_TABLE (0xC00000FF) during mntgen spawn, which
 * means the UNWIND_INFO encoding is still subtly wrong from Windows'
 * point of view.
 *
 * Candidate next-step diagnostics (when picked back up):
 *   - Attach windbg, break on STATUS_BAD_FUNCTION_TABLE first chance,
 *     read which RUNTIME_FUNCTION Windows just rejected and inspect
 *     its UNWIND_INFO bytes vs the spec.
 *   - Try the V8 unwinding-info-win64.cc layout verbatim (separate
 *     UNWIND_INFO struct in static data, computed offset).
 *   - Check whether the typecom slab's inner allocations need their
 *     own per-snippet RUNTIME_FUNCTIONs rather than relying on the
 *     slab's single registration.
 */

#define UNWIND_HEADER_SIZE	16	/* reserve at start of every JIT region */

/* Per-region tracking. Each registered region needs its own
 * RUNTIME_FUNCTION because BeginAddress/EndAddress differ. The
 * UnwindData offset is fixed (0) because the UNWIND_INFO lives at
 * the start of every region. */
typedef struct JitRegion {
	void			*base;		/* region start (page-aligned) */
	SIZE_T			length;		/* total region length in bytes */
	RUNTIME_FUNCTION	rt;		/* what the callback returns */
} JitRegion;

#define MAX_JIT_REGIONS		2048

static JitRegion regions[MAX_JIT_REGIONS];
static volatile LONG region_count = 0;	/* high-water mark, never decreases */
static volatile LONG region_live = 0;	/* count currently registered */

/* Callback invoked by Windows during SEH unwinding when ControlPc
 * falls inside a registered JIT region. The Context we pass at
 * registration time is the index into regions[]; we return its
 * pre-filled RUNTIME_FUNCTION. */
static PRUNTIME_FUNCTION CALLBACK
jit_unwind_callback(DWORD64 ControlPc, PVOID Context)
{
	intptr_t idx = (intptr_t)Context;
	(void)ControlPc;	/* range already validated by Windows via BaseAddress/Length */
	if(idx < 0 || idx >= region_count)
		return NULL;
	if(regions[idx].base == NULL)
		return NULL;	/* slot has been unregistered */
	return &regions[idx].rt;
}

/* Public entry: write UNWIND_INFO at the start of [base, base+length)
 * and register the region with Windows so SEH can unwind through it.
 * Caller MUST treat the first UNWIND_HEADER_SIZE bytes as reserved
 * (no JIT code goes there).
 *
 * Returns 0 on success, -1 on failure. On failure the region is not
 * registered; the caller can still use it but unwind through it will
 * crash (i.e. behaviour matches before this fix).
 */
int
jit_unwind_register(void *base, size_t length, int kind)
{
	if(base == NULL || length < UNWIND_HEADER_SIZE)
		return -1;

	LONG idx = InterlockedIncrement(&region_count) - 1;
	if(idx >= MAX_JIT_REGIONS) {
		/* Reached the table cap. We don't decrement region_count
		 * because some other thread may already have allocated
		 * after us; idx becomes a permanent "no slot here". */
		return -1;
	}

	/* Write UNWIND_INFO at offset 0 of the region.
	 *
	 * All JIT regions in InferNode are entered via comvec, which is
	 * itself a JIT region with this prologue (see comp-amd64.c line 2078,
	 * `Save callee-saved registers`):
	 *
	 *     push RSI         ; 1 byte, prolog offset 0..0
	 *     push RDI         ; 1 byte, prolog offset 1..1
	 *     push RBX         ; 1 byte, prolog offset 2..2
	 *     push R12         ; 2 bytes (REX), prolog offset 3..4
	 *     push R14         ; 2 bytes (REX), prolog offset 5..6
	 *     push R15         ; 2 bytes (REX), prolog offset 7..8
	 *     ; end of prolog at offset 9, then JMP into module code
	 *
	 * Module code runs inside comvec's stack frame (JMP, not CALL — no
	 * new return address on the stack). So when Windows unwinds at ANY
	 * PC inside the JIT arena (comvec or any module), RSP is 48 bytes
	 * below the original caller-of-comvec frame, with the 6 callee-saved
	 * registers saved in that 48-byte slot. The same UNWIND_INFO applies
	 * to every JIT region.
	 *
	 * UNWIND_CODE order is REVERSE prolog order (Windows unwinds backwards).
	 * Each UNWIND_CODE is 2 bytes: (CodeOffset, (RegOrOp<<4)|OpCode).
	 * UWOP_PUSH_NONVOL = 0. CodeOffset is the byte after the push instruction.
	 *
	 * Reverse-order codes:
	 *   push R15 at prolog end offset 9: {0x09, 0xF0}
	 *   push R14 at offset 7:            {0x07, 0xE0}
	 *   push R12 at offset 5:            {0x05, 0xC0}
	 *   push RBX at offset 3:            {0x03, 0x30}
	 *   push RDI at offset 2:            {0x02, 0x70}
	 *   push RSI at offset 1:            {0x01, 0x60}
	 *
	 * Header (4 bytes) + 6 codes (12 bytes) = 16 bytes — exactly our
	 * reserved JIT_UNWIND_HEADER size, 4-byte-aligned as required.
	 */
	UCHAR *u = (UCHAR*)base;
	if(kind == JIT_UNWIND_COMVEC_FRAME) {
		/* 6 PUSH_NONVOL describing comvec's prolog (see above). */
		u[0]  = 0x01;	u[1]  = 0x09;	u[2]  = 0x06;	u[3]  = 0x00;
		u[4]  = 0x09;	u[5]  = 0xF0;	/* push R15 at offset 9 */
		u[6]  = 0x07;	u[7]  = 0xE0;	/* push R14 at offset 7 */
		u[8]  = 0x05;	u[9]  = 0xC0;	/* push R12 at offset 5 */
		u[10] = 0x03;	u[11] = 0x30;	/* push RBX at offset 3 */
		u[12] = 0x02;	u[13] = 0x70;	/* push RDI at offset 2 */
		u[14] = 0x01;	u[15] = 0x60;	/* push RSI at offset 1 */
	} else {
		/* JIT_UNWIND_LEAF: typecom init/destroy snippets called
		 * directly from C. No prolog, no codes. Windows treats
		 * the frame as a no-op leaf: return address at [RSP]. */
		u[0] = 0x01;	/* Version=1, Flags=0 */
		u[1] = 0x00;	/* SizeOfProlog */
		u[2] = 0x00;	/* CountOfCodes */
		u[3] = 0x00;	/* FrameRegister=0, FrameOffset=0 */
		/* bytes 4..15: zero. */
		u[4]=0; u[5]=0; u[6]=0; u[7]=0;
		u[8]=0; u[9]=0; u[10]=0; u[11]=0;
		u[12]=0; u[13]=0; u[14]=0; u[15]=0;
	}

	regions[idx].base = base;
	regions[idx].length = length;
	/* RUNTIME_FUNCTION fields are offsets relative to BaseAddress
	 * (which is `base`, passed to RtlInstallFunctionTableCallback). */
	regions[idx].rt.BeginAddress = UNWIND_HEADER_SIZE;	/* code starts here */
	regions[idx].rt.EndAddress = (DWORD)length;
	regions[idx].rt.UnwindData = 0;				/* UNWIND_INFO at offset 0 */

	/* TableIdentifier must have its low 2 bits set to 0x3 to indicate
	 * a callback-style dynamic function table (vs static one passed to
	 * RtlAddFunctionTable). MSDN: "DynamicBase | 0x3". */
	BOOLEAN ok = RtlInstallFunctionTableCallback(
			(DWORD64)base | 0x3,
			(DWORD64)base,
			(DWORD)length,
			jit_unwind_callback,
			(PVOID)(intptr_t)idx,
			NULL);
	if(!ok) {
		DWORD err = GetLastError();
		if(trace())
			fprintf(stderr, "jit_unwind_register: RtlInstall FAILED base=%p len=%zu err=%lu\n",
				base, (size_t)length, (unsigned long)err);
		regions[idx].base = NULL;	/* mark slot dead so callback returns NULL */
		return -1;
	}

	if(trace())
		fprintf(stderr, "jit_unwind_register: OK idx=%ld base=%p len=%zu\n",
			(long)idx, base, (size_t)length);

	InterlockedIncrement(&region_live);
	return 0;
}

/* Public entry: undo jit_unwind_register for a region. Safe to call
 * even if registration failed (the matching RtlDeleteFunctionTable is
 * a no-op in that case). */
void
jit_unwind_unregister(void *base)
{
	if(base == NULL)
		return;

	/* Find the slot for `base` and zero it so the callback stops
	 * returning a stale RUNTIME_FUNCTION if Windows ever calls back
	 * after RtlDeleteFunctionTable (it shouldn't, but defensive). */
	LONG count = region_count;
	for(LONG i = 0; i < count; i++) {
		if(regions[i].base == base) {
			regions[i].base = NULL;
			InterlockedDecrement(&region_live);
			break;
		}
	}

	RtlDeleteFunctionTable((PRUNTIME_FUNCTION)((DWORD64)base | 0x3));
}
