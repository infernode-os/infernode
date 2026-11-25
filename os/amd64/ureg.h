/*
 * os/amd64/ureg.h -- the exception frame as os/port sees it.
 *
 * os/port's clock and trap code takes a Ureg* and reads the interrupted
 * pc.  The trap layer's full Trapframe (trap.h) is the machine's; this
 * is the slice the shared kernel is written against, filled in by
 * portclocktick() from the frame it has.
 */

#ifndef _OS_AMD64_UREG_H_
#define _OS_AMD64_UREG_H_

#include <stdint.h>

typedef struct Ureg Ureg;
struct Ureg
{
	uintptr	pc;
	uintptr	sp;
};

#endif
