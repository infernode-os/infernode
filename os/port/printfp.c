/*
 * snprint and sprint, the two variadic entry points through which a
 * Dis REAL is formatted, compiled WITH floating point.
 *
 * Under AAPCS64 a double passed to a variadic function arrives in a
 * vector register, and va_start spills v0-v7 into the va_list's save
 * area for va_arg to find. A function compiled -mgeneral-regs-only --
 * the rest of os/port, and devcons.c where these two used to live --
 * spills only x0-x7. The double never reaches the save area, and the
 * %g converter (libmath/gfltconv.c, which IS built with FP) reads
 * whatever was left there. On the bare-metal kernel every Limbo
 * sprint("%g", ...) and every string of a real printed garbage:
 * 70.0 as 4.15e-322, 37.81 under %.6f as 0.000000. Matrix's
 * geo-demo writes positions with %.6f and reads them back, and on
 * those numbers it spun holding the VM until the board was reset.
 *
 * The callers that pass a real are exactly these two: xprint
 * (libinterp/runt.c, Limbo's sprint and print), cvtfc
 * (libinterp/string.c, string of a real) and devprog.c's /prog heap
 * reader. print, fprint and the rest stay in devcons.c under
 * -mgeneral-regs-only; nothing hands them a double.
 *
 * Built with FP and -mno-implicit-float (tests/host/baremetal_test.sh):
 * FP so va_start spills v0-v7, and no implicit float so that spill is
 * all the code does with them. Without it clang copies the va_list
 * through q0/q1, a write to FP state that would be wrong if this ran
 * under an interrupt taken from a process with live FP registers.
 * With it the vector registers are read and never written. FP/SIMD
 * access is enabled in l.S before any C runs.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"

int
snprint(char *s, int n, char *fmt, ...)
{
	va_list arg;

	va_start(arg, fmt);
	n = vseprint(s, s+n, fmt, arg) - s;
	va_end(arg);

	return n;
}

int
sprint(char *s, char *fmt, ...)
{
	int n;
	va_list arg;

	va_start(arg, fmt);
	n = vseprint(s, s+PRINTSIZE, fmt, arg) - s;
	va_end(arg);

	return n;
}
