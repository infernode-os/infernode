/*
 * x86-64 (amd64) type foundation for the native kernel.
 *
 * Derived from this tree's Inferno/arm64/include/u.h with the changes
 * x86-64 needs.  As there, ulong is 64 bits (InferNode is LP64
 * throughout; os/port stores pointers in ulong in many places, which is
 * correct by construction here), FPdbleword names its halves because
 * clang has no Plan 9 anonymous struct, and the variadic argument
 * handling is the compiler's <stdarg.h> rather than a hand-rolled
 * char*.
 *
 * The floating point constants are the x87 control/status word bits,
 * the same layout Linux/amd64/include/fpuctl.h uses, because that is
 * the hardware an amd64 kernel runs on.  os/port's FP save/restore
 * arrives with the Dis VM; until then nothing here touches the x87.
 *
 * Following Plan 9 convention this header has no include guard: every
 * .c includes it first, once, by hand.
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

/* the intN/uintN spelling, which include/libsec.h and mp.h use */
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
 * setjmp/longjmp for kernel use.  x86-64's callee-saved state is rbx,
 * rbp, r12-r15, rsp and rip.  The Label the scheduler and the error
 * machinery use is the platform dat.h's, not this.
 */
typedef	long	jmp_buf[32];
#define	JMPBUFSP	0
#define	JMPBUFPC	1
#define	JMPBUFDPC	0

typedef union FPdbleword FPdbleword;

/* little endian, as on every x86 */
union FPdbleword
{
	double	x;
	struct {
		u32int	lo;
		u32int	hi;
	} w;
};

/* FCR: x87 control word, exception masks */
#define	FPINEX		(1<<5)
#define	FPUNFL		((1<<4)|(1<<1))
#define	FPOVFL		(1<<3)
#define	FPZDIV		(1<<2)
#define	FPINVAL		(1<<0)

/* FCR: rounding control, bits 11:10 */
#define	FPRNR		(0<<10)		/* to nearest, ties to even */
#define	FPRNINF		(1<<10)		/* toward -infinity */
#define	FPRPINF		(2<<10)		/* toward +infinity */
#define	FPRZ		(3<<10)		/* toward zero */
#define	FPRMASK		(3<<10)

/* FCR: precision control, bits 9:8 */
#define	FPPEXT		(3<<8)
#define	FPPSGL		(0<<8)
#define	FPPDBL		(2<<8)
#define	FPPMASK		(3<<8)

/* FSR: the x87 status word's accrued exception bits */
#define	FPAINEX		(1<<5)
#define	FPAUNFL		(1<<4)
#define	FPAOVFL		(1<<3)
#define	FPAZDIV		(1<<2)
#define	FPAINVAL	(1<<0)

/*
 * Plan 9 idioms used throughout the kernel and libkern.  USED marks a
 * value kept deliberately but not read; SET silences a "may be used
 * uninitialised" warning where the programmer knows better than the
 * compiler's flow analysis.  Both are variadic: os/port calls them with
 * more than one variable.
 */
#define	USED(...)	((void)(__VA_ARGS__))
#define	SET(...)

#include <stdarg.h>
