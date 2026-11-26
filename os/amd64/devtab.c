/*
 * The device table: which devices this kernel includes.
 *
 * Nil-terminated, because devno() and chandevreset() walk it until nil.
 * One device so far: the pipe, which is what proves the channel layer
 * without a root filesystem or a console queue.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

extern Dev	pipedevtab;

Dev*	devtab[] =
{
	&pipedevtab,		/* '|' -- pipes */
	nil,
};
