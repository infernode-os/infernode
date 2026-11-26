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

extern Dev	consdevtab;
extern Dev	hostringdevtab;
extern Dev	mntdevtab;
extern Dev	pipedevtab;
extern Dev	progdevtab;
extern Dev	rootdevtab;

Dev*	devtab[] =
{
	&rootdevtab,		/* '/' -- the namespace root */
	&consdevtab,		/* 'c' -- /dev/cons and friends */
	&hostringdevtab,	/* '~' -- 9vm's host rings as 9P streams */
	&mntdevtab,		/* 'M' -- the 9P client behind mount */
	&progdevtab,		/* 'p' -- /prog: wait, ctl, status, heap */
	&pipedevtab,		/* '|' -- pipes */
	nil,
};
