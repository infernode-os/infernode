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
};

/*
 * The image is reproduced rather than copied: .text and .rodata are
 * never written and are read straight from where they run; .data is
 * read from the copy l.S takes into __datastash before any C code
 * runs, which is the only moment it is still what was loaded (see
 * kernel.ld). That is byte-identical to the file the loader was given
 * -- the harness compares SHA-1s -- and costs ~100KB of .bss for the
 * data copy instead of a four-megabyte buffer and a two-megabyte
 * memmove at boot.
 */
extern char _start[], __data_start[], edata[], __datastash[];

static Dirtab boottab[]={
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"bootimage",	{Qimage},		0,	0444,
};

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
	boottab[Qimage].length = edata - _start;
	return devstat(c, db, n, boottab, nelem(boottab), devgen);
}

static Chan*
bootopen(Chan *c, int omode)
{
	boottab[Qimage].length = edata - _start;
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

	{
		ulong tlen, len;
		uchar *src;

		tlen = __data_start - _start;
		len = edata - _start;
		if(off < 0 || off >= len)
			return 0;
		if(off + n > len)
			n = len - off;
		if(off < tlen){
			if(off + n > tlen)
				n = tlen - off;	/* one segment per read */
			src = (uchar*)_start + off;
		}else
			src = (uchar*)__datastash + (off - tlen);
		memmove(a, src, n);
		return n;
	}
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
