/*
 * #B -- the running kernel, as a file.
 *
 * The machine boots by having a host push an image down the serial line
 * into serialboot, which is fine for development and is not a way to
 * own a computer. To boot on its own the Pi needs that image ON its
 * card, and the image is already in memory: it is what serialboot
 * loaded and what is executing.
 *
 * So publish it. Installing the running kernel then needs no new
 * mechanism and no transfer at all -- it is
 *
 *	cp /dev/bootimage /n/dos/infernode8.img
 *
 * with the ordinary cp, through the ordinary filesystem, and anything
 * that can copy a file can do it.
 *
 * A SNAPSHOT is served rather than the live memory, and that is the
 * whole subtlety here. The image runs from where it was loaded, so its
 * data segment is being modified the entire time the machine is up;
 * reading it later would hand out a kernel whose initialised variables
 * are whatever they had become, which would boot into a state no fresh
 * image was ever in. The copy is taken at the top of kmain, before any
 * C code has had a chance to write to .data.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

enum{
	Qdir,
	Qimage,

	/*
	 * Room for the image, in .bss so it costs nothing in the file it
	 * is holding a copy of. The kernel is around 750KB; four
	 * megabytes is headroom rather than a limit worth tuning, and the
	 * snapshot refuses rather than truncates if it is ever exceeded.
	 */
	Maxbootimg = 4*1024*1024,
};

/* edata is already declared as char[] by the portable headers */

static uchar bootimg[Maxbootimg];
static long bootimglen;

static Dirtab boottab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"bootimage",	{Qimage},		0,	0444,
};

/*
 * Copy the loaded image out of the way of the running kernel.
 *
 * Called from kmain before anything else, because "before anything
 * else" is the only time this is the image that was loaded rather than
 * the image plus however far it has run.
 */
void
bootimgsnap(void)
{
	uchar *start;
	long n;

	start = (uchar*)KTZERO;
	n = (uchar*)edata - start;
	if(n <= 0 || n > Maxbootimg){
		bootimglen = 0;
		return;
	}
	memmove(bootimg, start, n);
	bootimglen = n;
}

static Chan*
bootattach(char *spec)
{
	return devattach('B', spec);
}

static Walkqid*
bootwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, boottab, nelem(boottab), devgen);
}

static int
bootstat(Chan *c, uchar *db, int n)
{
	boottab[Qimage].length = bootimglen;
	return devstat(c, db, n, boottab, nelem(boottab), devgen);
}

static Chan*
bootopen(Chan *c, int omode)
{
	boottab[Qimage].length = bootimglen;
	return devopen(c, omode, boottab, nelem(boottab), devgen);
}

static void
bootclose(Chan *c)
{
	USED(c);
}

static long
bootread(Chan *c, void *a, long n, vlong off)
{
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, boottab, nelem(boottab), devgen);
	if((ulong)c->qid.path != Qimage)
		error(Ebadusefd);

	if(bootimglen == 0)
		error("no boot image was captured");
	if(off >= bootimglen)
		return 0;
	if(off + n > bootimglen)
		n = bootimglen - off;
	memmove(a, bootimg + off, n);
	return n;
}

static long
bootwrite(Chan*, void*, long, vlong)
{
	error(Eperm);
	return 0;
}

Dev bootdevtab = {
	'B',
	"boot",

	devreset,
	devinit,
	devshutdown,
	bootattach,
	bootwalk,
	bootstat,
	bootopen,
	devcreate,
	bootclose,
	bootread,
	devbread,
	bootwrite,
	devbwrite,
	devremove,
	devwstat,
};
