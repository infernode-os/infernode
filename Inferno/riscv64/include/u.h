/*
 * RISC-V (RV64GC, LP64D) type foundation for the native kernel.
 *
 * The same foundation as Inferno/arm64/include/u.h, which says why each
 * piece is as it is: LP64 (ulong holds a pointer, as os/port assumes),
 * the compiler's own <stdarg.h> (the psABI passes variadic doubles in
 * integer registers; no hand-rolled va_list can know that), and a
 * named FPdbleword member.
 *
 * What differs is the floating-point control word. RISC-V has one CSR,
 * fcsr: the rounding mode in bits 7:5 and the accrued exception flags
 * in bits 4:0. It has no trap enables at all, so the FCR's exception
 * bits below name fcsr's flag positions and nothing honours them; the
 * rounding mode is real. libkernfp/fpu.c reads and writes fcsr in this
 * layout, shifted exactly as these say.
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

/*
 * The intN/uintN spelling of the same widths. Both exist because the
 * tree uses both: os/port and libkern say u32int, while include/libsec.h
 * and include/mp.h say int32. MacOSX/arm64/include/lib9.h defines both
 * for exactly this reason, so the native header has to as well.
 */
typedef	signed char		int8;
typedef	short			int16;
typedef	int			int32;
typedef	long long		int64;

typedef	unsigned char		uint8;
typedef	unsigned short		uint16;
typedef	unsigned int		uint32;
typedef	unsigned long long	uint64;

typedef	unsigned long		uintptr;
typedef	long			intptr;
typedef	unsigned long		usize;
typedef	long			ssize;

typedef	unsigned int		mpdigit;	/* for include/mp.h */

/*
 * setjmp/longjmp for kernel use.  The RISC-V psABI's callee-saved
 * state is ra, sp, s0-s11 and fs0-fs11: 26 doublewords. 32 gives room
 * and keeps the buffer 16-byte aligned, which the psABI requires of
 * the stack pointer it will restore.
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

/* FCR: fcsr's flag positions, for exception "enables" RISC-V does not have */
#define	FPINEX		(1<<0)		/* inexact */
#define	FPUNFL		(1<<1)		/* underflow */
#define	FPOVFL		(1<<2)		/* overflow */
#define	FPZDIV		(1<<3)		/* divide by zero */
#define	FPINVAL		(1<<4)		/* invalid operation */

/* FCR: rounding mode, fcsr.frm in bits 7:5 */
#define	FPRNR		(0<<5)		/* to nearest, ties to even */
#define	FPRZ		(1<<5)		/* toward zero */
#define	FPRNINF		(2<<5)		/* toward -infinity */
#define	FPRPINF		(3<<5)		/* toward +infinity */
#define	FPRMASK		(7<<5)

/* no precision control: a double is a double */
#define	FPPEXT		0
#define	FPPSGL		0
#define	FPPDBL		0
#define	FPPMASK		0

/* FSR: fcsr.fflags, bits 4:0 */
#define	FPAINEX		(1<<0)
#define	FPAUNFL		(1<<1)
#define	FPAOVFL		(1<<2)
#define	FPAZDIV		(1<<3)
#define	FPAINVAL	(1<<4)

/*
 * Plan 9 idioms used throughout the kernel and libkern.  USED marks a
 * value kept deliberately but not read; SET silences a "may be used
 * uninitialised" warning where the programmer knows better than the
 * compiler's flow analysis.  They live here rather than in lib9.h
 * because kernel sources include u.h and ../port/lib.h but never
 * lib9.h, while libkern reaches u.h through lib9.h -- so this is the
 * one place that serves both.
 */
/*
 * Variadic, because os/port calls it with more than one variable --
 * os/port/nodynld.c:28 is USED(fd, tab, ntab). The hosted
 * MacOSX/arm64/include/lib9.h defines a single-argument version, which
 * is fine there because it never compiles kernel sources.
 *
 * The comma expression evaluates each operand and discards the result,
 * which is what suppresses the unused-parameter warning; casting to
 * void keeps it from being read as a value.
 */
#define	USED(...)	((void)(__VA_ARGS__))

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
