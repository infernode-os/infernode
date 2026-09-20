/*
 * Compile-time checks on the arm64 type foundation.
 *
 * This file emits almost no code; it exists so that the assumptions the
 * os/port import rests on are checked by every build rather than
 * believed.  Getting one of these wrong does not produce a compile error
 * somewhere useful -- it produces a kernel that boots and then corrupts
 * memory in a way that looks like anything but a type definition.
 *
 * The FPdbleword check earned its place immediately: written as upstream
 * writes it (ulong halves, correct when ulong was 32 bits), the union
 * silently became twice the size of the double it aliases, so every read
 * of the high half would have come from past the end of the value.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

/*
 * LP64 is the load-bearing assumption of the whole import.  Upstream
 * os/port stores pointers in ulong in ~160 places; that is correct only
 * because ulong is pointer-sized here.  If this ever fails, the import
 * is unsafe, not merely unportable.
 */
_Static_assert(sizeof(ulong) == 8, "ulong must be 64-bit (LP64)");
_Static_assert(sizeof(ulong) == sizeof(void*), "ulong must hold a pointer");
_Static_assert(sizeof(uintptr) == sizeof(void*), "uintptr must hold a pointer");
_Static_assert(sizeof(intptr) == sizeof(void*), "intptr must hold a pointer");

/* fixed-width types must be fixed width regardless of the word size */
_Static_assert(sizeof(u8int) == 1, "u8int");
_Static_assert(sizeof(u16int) == 2, "u16int");
_Static_assert(sizeof(u32int) == 4, "u32int");
_Static_assert(sizeof(u64int) == 8, "u64int");
_Static_assert(sizeof(s32int) == 4, "s32int");
_Static_assert(sizeof(vlong) == 8, "vlong");
_Static_assert(sizeof(uvlong) == 8, "uvlong");

/* Rune is a full code point; mpdigit must agree with include/mp.h */
_Static_assert(sizeof(Rune) == 4, "Rune must be 32-bit");
_Static_assert(sizeof(mpdigit) == 4, "mpdigit must match include/mp.h");

/* the union must alias a double exactly, not merely contain one */
_Static_assert(sizeof(FPdbleword) == sizeof(double),
	"FPdbleword must alias a double exactly (use u32int halves, not ulong)");

/* jmp_buf must hold AArch64's callee-saved state and keep SP alignment */
_Static_assert(sizeof(jmp_buf) >= (13+8)*8, "jmp_buf too small for AArch64");
_Static_assert((sizeof(jmp_buf) % 16) == 0, "jmp_buf must stay 16-byte aligned");

/*
 * The variadic machinery must be the compiler's.  Upstream's arm u.h
 * ships a hand-rolled va_list (typedef char*) that steps arguments by a
 * hardcoded 4 bytes, which cannot be made correct on AAPCS64.  Checking
 * sizeof(va_list) is not the test -- Apple's arm64 ABI legitimately uses
 * char* while ELF AAPCS64 uses a five-field struct.  What matters is
 * that va_start/va_arg/va_end come from <stdarg.h> and actually work, so
 * exercise them.
 */
static int
vsum(int n, ...)
{
	va_list ap;
	int i, t;

	t = 0;
	va_start(ap, n);
	for(i = 0; i < n; i++)
		t += va_arg(ap, int);
	va_end(ap);
	return t;
}

int
typecheck(void)
{
	return vsum(3, 1, 2, 3) == 6;
}
