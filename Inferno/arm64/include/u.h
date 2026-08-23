/*
 * AArch64 (arm64) type foundation for the native kernel.
 *
 * Derived from upstream Inferno's Inferno/arm/include/u.h, with the
 * changes AArch64 and LP64 require.  Three of those changes are not
 * cosmetic:
 *
 *   va_list.  Upstream defines its own (typedef char*) with argument
 *   stepping hardcoded to 4 bytes.  That is simply wrong under AAPCS64,
 *   where a va_list is a five-field struct and arguments are split
 *   between general-purpose and SIMD save areas.  There is no way to
 *   patch the sizes and be correct; the only right answer is the
 *   compiler's own <stdarg.h>, which is one of the handful of headers
 *   guaranteed to exist in a freestanding implementation.
 *
 *   ulong is 64 bits.  InferNode is LP64 throughout -- see
 *   MacOSX/arm64/include/lib9.h, include/interp.h (WORD is intptr) and
 *   include/isa.h (IBY2WD is sizeof(void*)).  Upstream os/port stores
 *   pointers in ulong in about 160 places; under LP64 that convention
 *   is correct by construction rather than broken, which is what makes
 *   importing os/port tractable at all.  Do not narrow ulong here.
 *
 *   FPdbleword has a named member.  Upstream uses a Plan 9 anonymous
 *   struct; clang has no working equivalent (-fplan9-extensions is a GCC
 *   flag, and -fms-extensions silently computes the wrong address when a
 *   member is not at offset 0), so this tree names them.  See
 *   os/bcm2837/README.md.
 *
 * The 32-bit-ARM FP emulation control bits are gone: AArch64 mandates
 * FP/SIMD and uses FPCR/FPSR, not the FCR/FSR layout above.
 */

#define nil		((void*)0)

typedef	unsigned char		uchar;
typedef	unsigned short		ushort;
typedef	unsigned int		uint;
typedef	unsigned long		ulong;		/* 64 bits: LP64 */
typedef	signed char		schar;
typedef	long long		vlong;
typedef	unsigned long long	uvlong;

typedef	uint			Rune;

typedef	unsigned char		u8int;
typedef	unsigned short		u16int;
typedef	unsigned int		u32int;
typedef	unsigned long long	u64int;

typedef	signed char		s8int;
typedef	short			s16int;
typedef	int			s32int;
typedef	long long		s64int;

typedef	unsigned long		uintptr;
typedef	long			intptr;
typedef	unsigned long		usize;
typedef	long			ssize;

typedef	unsigned int		mpdigit;	/* for include/mp.h */

/*
 * setjmp/longjmp for kernel use.  AArch64 requires the callee-saved
 * state to be preserved: x19-x28, x29 (frame pointer), x30 (link
 * register), the stack pointer, and d8-d15.  That is 13 doublewords
 * plus 8 more for the SIMD halves; 32 gives room and keeps the buffer
 * 16-byte aligned, which the architecture requires of the stack pointer
 * it will restore.
 *
 * Note this is NOT the Label used by the scheduler -- that lives in the
 * platform dat.h and saves only sp and pc.
 */
typedef	long	jmp_buf[32];
#define	JMPBUFSP	0
#define	JMPBUFPC	1
#define	JMPBUFDPC	0

typedef union FPdbleword FPdbleword;

/*
 * The halves are u32int, NOT ulong.
 *
 * Upstream writes these as ulong, which was right when ulong was 32
 * bits: the two halves then overlaid a double exactly.  Under LP64 that
 * same declaration makes the struct 16 bytes and the union twice the
 * size of the double it is supposed to alias, so every read of hi would
 * come from past the end of the value.  These fields are the two halves
 * of an IEEE 754 double and are 32 bits by definition, so they must be
 * spelled that way rather than inherited from the word size.
 */
union FPdbleword
{
	double	x;
	struct {	/* little endian */
		u32int	lo;
		u32int	hi;
	} w;
};

/*
 * AArch64 always has hardware FP/SIMD, controlled by FPCR (rounding and
 * exception masks) and FPSR (accrued exception flags).  These replace
 * the 32-bit ARM FCR/FSR definitions entirely.
 */

/* FPCR: exception trap enables */
#define	FPINEX		(1<<12)		/* inexact */
#define	FPUNFL		(1<<11)		/* underflow */
#define	FPOVFL		(1<<10)		/* overflow */
#define	FPZDIV		(1<<9)		/* divide by zero */
#define	FPINVAL		(1<<8)		/* invalid operation */

/* FPCR: rounding mode, bits 23:22 */
#define	FPRNR		(0<<22)		/* to nearest, ties to even */
#define	FPRPINF		(1<<22)		/* toward +infinity */
#define	FPRNINF		(2<<22)		/* toward -infinity */
#define	FPRZ		(3<<22)		/* toward zero */
#define	FPRMASK		(3<<22)

/* precision is not selectable on AArch64; kept so portable code links */
#define	FPPEXT		0
#define	FPPSGL		0
#define	FPPDBL		0
#define	FPPMASK		0

/* FPSR: accrued exception flags */
#define	FPAINEX		(1<<4)
#define	FPAUNFL		(1<<3)
#define	FPAOVFL		(1<<2)
#define	FPAZDIV		(1<<1)
#define	FPAINVAL	(1<<0)

/*
 * Plan 9 idioms used throughout the kernel and libkern.  USED marks a
 * value kept deliberately but not read; SET silences a "may be used
 * uninitialised" warning where the programmer knows better than the
 * compiler's flow analysis.  They live here rather than in lib9.h
 * because kernel sources include u.h and ../port/lib.h but never
 * lib9.h, while libkern reaches u.h through lib9.h -- so this is the
 * one place that serves both.
 */
#define	USED(x)		if(x){}else{}

/*
 * SET is a no-op, matching MacOSX/arm64/include/lib9.h. It marks a
 * variable the programmer knows is assigned before use where the
 * compiler's flow analysis cannot see it -- it must NOT assign, or it
 * would mask a genuine use-before-set. Variadic because upstream calls
 * it with more than one variable (os/port/alloc.c:839).
 */
#define	SET(...)

/*
 * Use the compiler's variadic argument handling.  See the note above:
 * the Plan 9 va_list cannot be made correct on AAPCS64.
 */
#include <stdarg.h>
