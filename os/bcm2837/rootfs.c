/*
 * The in-kernel root filesystem.
 *
 * STANDS IN FOR A GENERATED FILE. Upstream's os/port/mkroot reads the
 * "root" section of a kernel configuration -- a list of host files to
 * embed -- and emits $CONF.root.h containing roottab, rootdata and
 * rootmaxq, with each file's contents compiled in as a byte array. That
 * is how a native Inferno kernel carries /osinit.dis and the rest of
 * its boot filesystem with no storage driver.
 *
 * There is no configuration file or mk build for this port yet, so the
 * tables are written by hand in exactly the shape mkroot emits. Keeping
 * the layout identical is the point: when the build machinery lands,
 * this file is deleted rather than adapted.
 *
 * What is here is the minimum that makes the namespace real: a root
 * directory with one subdirectory. That is enough for devtab to have a
 * genuine entry, for a Chan to be attached to a device and closed
 * (which faulted through a nil function pointer while devtab was
 * empty), and for a walk to have somewhere to go.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * Qids are indices into these tables, so the two must stay in step and
 * rootmaxq must equal their length. devroot.c indexes rootdata by
 * c->qid.path without bounds-checking beyond rootmaxq.
 */
int rootmaxq = 2;

Dirtab roottab[2] =
{
	{ "",		{0, 0, QTDIR},	0,	0555 },	/* / */
	{ "dev",	{1, 0, QTDIR},	0,	0555 },	/* /dev */
};

Rootdata rootdata[2] =
{
	/* dotdot, ptr, size, sizep */
	{ 0,	&roottab[1],	1,	nil },	/* / : one child, at roottab[1] */
	{ 0,	nil,		0,	nil },	/* /dev : empty, parent is / */
};
