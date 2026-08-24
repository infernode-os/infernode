/*
 * The in-kernel root filesystem.
 *
 * STANDS IN FOR A GENERATED FILE. Upstream's os/port/mkroot reads the
 * "root" section of a kernel configuration -- a list of host files to
 * embed -- and emits $CONF.root.h containing roottab, rootdata and
 * rootmaxq, with each file's contents compiled in as a byte array. That
 * is how a native Inferno kernel carries /osinit.dis and the rest of
 * its boot filesystem with no storage driver: the files ARE the kernel
 * image.
 *
 * There is no configuration file or mk build for this port yet, so the
 * tables are written by hand in exactly the shape mkroot emits. Keeping
 * the layout identical is the point: when the build machinery lands,
 * this file is deleted rather than adapted.
 *
 * The bytes of /osinit.dis come from os/init/bcm2837init.b, compiled by
 * the Limbo compiler during the build and converted to a C array --
 * which is the same two steps mkroot performs, just spelled out in the
 * test harness rather than in an mkfile.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * Generated during the build from os/init/bcm2837init.b. Declared here
 * rather than defined so the bytecode is regenerated whenever the Limbo
 * source changes, instead of being committed and going stale.
 */
extern uchar	rootosinitcode[];
extern int	rootosinitlen;

/*
 * Qids are indices into these tables, so the two must stay in step and
 * rootmaxq must equal their length. devroot.c indexes rootdata by
 * c->qid.path without bounds-checking beyond rootmaxq.
 */
int rootmaxq = 3;

Dirtab roottab[3] =
{
	{ "",		{0, 0, QTDIR},	0,	0555 },	/* / */
	{ "dev",	{1, 0, QTDIR},	0,	0555 },	/* /dev */
	{ "osinit.dis",	{2, 0, QTFILE},	0,	0444 },	/* the initial Dis program */
};

Rootdata rootdata[3] =
{
	/* dotdot, ptr, size, sizep */
	{ 0,	&roottab[1],	2,	nil },			/* / : two children */
	{ 0,	nil,		0,	nil },			/* /dev : empty */
	{ 0,	rootosinitcode,	0,	&rootosinitlen },	/* /osinit.dis */
};
