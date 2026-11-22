/*
 * (This file was os/bcm2837/devsd.c. It moved here when a second
 * board, os/virt, put a virtio disk under it: all it asks of a board is
 * sdblkpresent(), sdblknblocks(), sdblkread(), sdblkreadn() and sdblkwrite(), declared
 * in the board's board.h. They were emmcread() and friends while the
 * only thing under #S was this SoC's card. "The SD card" below is
 * whatever answers those.)
 *
 * #S -- the SD card, as a file.
 *
 * The kernel's whole contribution to storage on this board: a byte
 * range you can read and write. It knows nothing about partitions and
 * nothing about filesystems, which is the point -- dossrv reads the FAT
 * boot partition out of this file and serves it as a namespace, and it
 * is an ordinary Limbo program doing so, with no more privilege than
 * anything else that can open a file.
 *
 * That division is why there is no partition support here. A partition
 * table is a data structure on the card, not a property of the
 * hardware, and a program that can read blocks can read one.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

enum{
	Qdir,
	Qctl,
	Qdata,
#ifdef NVME0
	Qnvme,		/* a second disk: one whole-disk file */
	Qnvmestat,	/* and what it says of itself */
#endif
	Qpart,		/* and upwards, one per partition */

	Blen	= 512,
	Maxblks	= 64,	/* blocks per multiple-block read: 32KB */
#ifdef NVME0
	Npart	= 24,
#else
	Npart	= 8,
#endif
	Namelen	= 32,
};

#define	Maxpartblk	(((vlong)1<<62)/Blen)	/* no partition starts or ends past this block */

typedef struct Part Part;
struct Part {
	char	name[Namelen];
	vlong	off;		/* bytes from the start of the card */
	vlong	len;
#ifdef NVME0
	int	nvme;		/* of the second disk, not the card */
#endif
};

static struct {
	QLock	q;
	uchar	buf[Blen];	/* one block, for unaligned edges */
	Part	part[Npart];
	int	npart;
} sd;

/*
 * Named byte ranges, created from outside.
 *
 * This is the whole of the kernel's involvement with partitions, and
 * deliberately so: a partition table is a data structure written on the
 * card, not a property of the hardware, so parsing one is policy. What
 * the kernel offers is the ability to NAME a range of the device and
 * have it appear as a file -- write "part boot 16384 1048576" to sdctl
 * and /dev/boot is those sectors and nothing else.
 *
 * Whoever reads the master boot record decides what to write here.
 * Plan 9's disk devices draw the line in the same place and for the
 * same reason.
 */
/*
 * Whether blocks startblk to startblk+nblk-1 are a range a partition can
 * be, on a device of devblks blocks (0 when that is not known).
 *
 * The numbers are whatever was written to sdctl, and those are what a
 * card's or a disk's partition table says: a start of ffffffff in an MBR
 * arrives as -1, a GPT's are 64 bits as they come. Nothing looked. A
 * negative start made every offset in the partition negative, and the
 * part of a block an unaligned read or write copies was then taken from
 * before the bounce buffer: the kernel's memory, read and written. A
 * start large enough for start*512 to wrap did the same; a length of
 * none, or negative, made a file with no end.
 */
static int
partok(vlong startblk, vlong nblk, vlong devblks)
{
	if(startblk < 0 || nblk <= 0)
		return 0;
	if(startblk > Maxpartblk || nblk > Maxpartblk - startblk)
		return 0;
	if(devblks > 0 && startblk >= devblks)
		return 0;
	return 1;
}

/* nil, or why not; it raises nothing, as the disk's own scan runs at boot with no error label */
static char*
addpart(char *name, vlong startblk, vlong nblk, vlong devblks, int nvme)
{
	Part *p;
	int i;

	if(name[0] == 0 || strchr(name, '/') != nil)
		return Ebadctl;
	if(!partok(startblk, nblk, devblks))
		return "bad partition";
	/* one that runs past the end of its device is cut at it */
	if(devblks > 0 && nblk > devblks - startblk)
		nblk = devblks - startblk;

	/* under the lock I/O takes: the table was changed with none held */
	qlock(&sd.q);
	for(i = 0; i < sd.npart; i++)
		if(strcmp(sd.part[i].name, name) == 0)
			break;
	if(i == sd.npart){
		if(sd.npart >= Npart){
			qunlock(&sd.q);
			return "too many partitions";
		}
		sd.npart++;
	}
	p = &sd.part[i];
	strncpy(p->name, name, Namelen-1);
	p->name[Namelen-1] = 0;
	p->off = startblk * Blen;
	p->len = nblk * Blen;
#ifdef NVME0
	p->nvme = nvme;
#else
	USED(nvme);
#endif
	qunlock(&sd.q);
	return nil;
}

static void
sdaddpart(char *name, vlong startblk, vlong nblk, vlong devblks, int nvme)
{
	char *e;

	e = addpart(name, startblk, nblk, devblks, nvme);
	if(e != nil)
		error(e);
}

#ifdef NVME0
/* nvme.c's, from the disk's partition table: in 512-byte units, as nvmepart */
char*
sdaddnvmepart(char *name, vlong start, vlong n)
{
	return addpart(name, start, n, nvmelength()/Blen, 1);
}
#endif

static vlong
sdlength(void)
{
	return (vlong)sdblknblocks() * Blen;
}

/*
 * Generate directory entries, since the set is not fixed: ctl, the
 * whole card, and then whatever partitions have been named.
 */
static int
sdgen(Chan *c, char *nm, Dirtab *tab, int ntab, int i, Dir *dp)
{
	Qid q;
	Part *p;

	USED(c); USED(nm); USED(tab); USED(ntab);

	q.vers = 0;
	q.type = QTFILE;

	if(i == DEVDOTDOT){
		q.path = Qdir;
		q.type = QTDIR;
		devdir(c, q, "#S", 0, eve, 0555, dp);
		return 1;
	}
	if(i == 0){
		q.path = Qctl;
		devdir(c, q, "sdctl", 0, eve, 0660, dp);
		return 1;
	}
	if(i == 1){
#ifdef NVME0
		if(!sdblkpresent())
			return 0;	/* booted from the drive, with no card */
#endif
		q.path = Qdata;
		devdir(c, q, "sdcard", sdlength(), eve, 0640, dp);
		return 1;
	}
	i -= 2;
#ifdef NVME0
	if(nvmepresent()){
		if(i == 0){
			q.path = Qnvme;
			devdir(c, q, "nvme0", nvmelength(), eve, 0640, dp);
			return 1;
		}
		if(i == 1){
			q.path = Qnvmestat;
			devdir(c, q, "nvmestat", 0, eve, 0444, dp);
			return 1;
		}
		i -= 2;
	}
#endif
	if(i >= sd.npart)
		return -1;
	p = &sd.part[i];
	q.path = Qpart + i;
	devdir(c, q, p->name, p->len, eve, 0640, dp);
	return 1;
}

static Chan*
sdattach(char *spec)
{
#ifdef NVME0
	if(!sdblkpresent() && !nvmepresent())
		error("no SD card");
#else
	if(!sdblkpresent())
		error("no SD card");
#endif
	return devattach('S', spec);
}

static Walkqid*
sdwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, sdgen);
}

static int
sdstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, sdgen);
}

static Chan*
sdopen(Chan *c, int omode)
{
	return devopen(c, omode, nil, 0, sdgen);
}

static void
sdclose(Chan *c)
{
	USED(c);
}

/*
 * Read or write a byte range that need not be block aligned.
 *
 * The card only moves whole 512-byte blocks, so the two ends of a
 * request are handled through a bounce buffer and the middle is done in
 * place. A write to a partial block is a READ, a patch and a write
 * back -- there is no way to write half a block, and pretending
 * otherwise would quietly destroy the bytes either side of the range
 * the caller asked for.
 */
static long
sdio(int iswrite, void *a, long n, vlong off, vlong base, vlong total)
{
	uchar *p;
	vlong blk;
	long done, m;
	int boff, nb;

	/*
	 * Clamp against this FILE's length before adding its base.
	 *
	 * The other order is wrong and quietly so: with off already made
	 * absolute, comparing it against the partition's LENGTH cuts the
	 * read short by exactly the partition's start offset -- so the
	 * tail of every partition after the first is unreadable, and a
	 * filesystem stored there simply appears truncated.
	 */
	if(total > 0){
		if(off >= total)
			return 0;
		if(off + n > total)
			n = total - off;
	}
	if(n <= 0)
		return 0;
	/* (a second check on what partok lets by: nothing below copes with either) */
	if(off < 0 || base < 0 || off > Maxpartblk*Blen || base > Maxpartblk*Blen)
		error(Ebadarg);
	off += base;

	p = a;
	done = 0;
	qlock(&sd.q);
	if(waserror()){
		qunlock(&sd.q);
		nexterror();
	}

	while(done < n){
		blk = (off + done) / Blen;
		boff = (off + done) % Blen;
		m = Blen - boff;
		if(m > n - done)
			m = n - done;

		if(!iswrite && boff == 0 && n - done >= Blen){
			/*
			 * Whole blocks in the middle go straight into the
			 * caller's buffer, many at a time: one command for
			 * up to Maxblks blocks where the controller can.
			 */
			nb = (n - done) / Blen;
			if(nb > Maxblks)
				nb = Maxblks;
			if(sdblkreadn(blk, p + done, nb) < 0)
				error(Eio);
			done += nb*Blen;
			continue;
		}
		if(!iswrite){
			if(sdblkread(blk, sd.buf) < 0)
				error(Eio);
			memmove(p + done, sd.buf + boff, m);
		}else{
			if(m != Blen){
				/* partial: keep what the caller did not send */
				if(sdblkread(blk, sd.buf) < 0)
					error(Eio);
			}
			memmove(sd.buf + boff, p + done, m);
			if(sdblkwrite(blk, sd.buf) < 0)
				error(Eio);
		}
		done += m;
	}

	poperror();
	qunlock(&sd.q);
	return done;
}

/*
 * Where a channel's byte 0 is, and how far it runs.
 */
static void
sdrange(Chan *c, vlong *base, vlong *len)
{
	ulong path;
	int i;

	path = (ulong)c->qid.path;
	if(path == Qdata){
		*base = 0;
		*len = sdlength();
		return;
	}
	i = path - Qpart;
	qlock(&sd.q);
	if(i < 0 || i >= sd.npart){
		qunlock(&sd.q);
		error(Ebadusefd);
	}
	*base = sd.part[i].off;
	*len = sd.part[i].len;
	qunlock(&sd.q);
}

static long
sdread(Chan *c, void *a, long n, vlong off)
{
	char buf[256];
	vlong base, len;
	int i, l;

	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, nil, 0, sdgen);

	if((ulong)c->qid.path == Qctl){
		l = snprint(buf, sizeof buf, "blocks %lld\n",
			(vlong)sdblknblocks());
		for(i = 0; i < sd.npart && l < sizeof buf - 64; i++)
			l += snprint(buf+l, sizeof buf - l, "part %s %lld %lld\n",
				sd.part[i].name, sd.part[i].off / Blen,
				sd.part[i].len / Blen);
		return readstr(off, a, n, buf);
	}

#ifdef NVME0
	if((ulong)c->qid.path == Qnvme)
		return nvmerw(0, a, n, off);
	if((ulong)c->qid.path == Qnvmestat){
		char *s;

		s = smalloc(READSTR);
		if(waserror()){
			free(s);
			nexterror();
		}
		nvmestat(s, READSTR);
		n = readstr(off, a, n, s);
		poperror();
		free(s);
		return n;
	}
#endif
	sdrange(c, &base, &len);
#ifdef NVME0
	if((ulong)c->qid.path >= Qpart && sd.part[c->qid.path - Qpart].nvme){
		if(off >= len)
			return 0;
		if(off + n > len)
			n = len - off;
		return nvmerw(0, a, n, base + off);
	}
#endif
	return sdio(0, a, n, off, base, len);
}

static long
sdwrite(Chan *c, void *a, long n, vlong off)
{
	Cmdbuf *cb;
	vlong base, len;

	if((ulong)c->qid.path == Qctl){
		cb = parsecmd(a, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf == 4 && strcmp(cb->f[0], "part") == 0)
			sdaddpart(cb->f[1], strtoll(cb->f[2], nil, 0),
				strtoll(cb->f[3], nil, 0), sdblknblocks(), 0);
#ifdef NVME0
		else if(cb->nf == 4 && strcmp(cb->f[0], "nvmepart") == 0){
			sdaddpart(cb->f[1], strtoll(cb->f[2], nil, 0),
				strtoll(cb->f[3], nil, 0), nvmelength()/Blen, 1);
		}
		else if(cb->nf == 1 && strcmp(cb->f[0], "nvmeslow") == 0)
			nvmeslow();
		else if(cb->nf == 1 && strcmp(cb->f[0], "flush") == 0)
			nvmeflush();
#endif
		else if(cb->nf == 1 && strcmp(cb->f[0], "flush") == 0)
			;	/* an SD card has no cache to flush */
		else
			error(Ebadctl);
		poperror();
		free(cb);
		return n;
	}

#ifdef NVME0
	if((ulong)c->qid.path == Qnvme)
		return nvmerw(1, a, n, off);
#endif
	sdrange(c, &base, &len);
#ifdef NVME0
	if((ulong)c->qid.path >= Qpart && sd.part[c->qid.path - Qpart].nvme){
		if(off >= len)
			return 0;
		if(off + n > len)
			n = len - off;
		return nvmerw(1, a, n, base + off);
	}
#endif
	return sdio(1, a, n, off, base, len);
}

Dev sddevtab = {
	'S',
	"sd",

	devreset,
	devinit,
	devshutdown,
	sdattach,
	sdwalk,
	sdstat,
	sdopen,
	devcreate,
	sdclose,
	sdread,
	devbread,
	sdwrite,
	devbwrite,
	devremove,
	devwstat,
};
