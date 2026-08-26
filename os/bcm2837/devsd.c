/*
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
	Qpart,		/* and upwards, one per partition */

	Blen	= 512,
	Npart	= 8,
	Namelen	= 32,
};

typedef struct Part Part;
struct Part {
	char	name[Namelen];
	vlong	off;		/* bytes from the start of the card */
	vlong	len;
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
static void
sdaddpart(char *name, vlong startblk, vlong nblk)
{
	Part *p;
	int i;

	for(i = 0; i < sd.npart; i++)
		if(strcmp(sd.part[i].name, name) == 0)
			break;
	if(i == sd.npart){
		if(sd.npart >= Npart)
			error("too many partitions");
		sd.npart++;
	}
	p = &sd.part[i];
	strncpy(p->name, name, Namelen-1);
	p->name[Namelen-1] = 0;
	p->off = startblk * Blen;
	p->len = nblk * Blen;
}

static vlong
sdlength(void)
{
	return (vlong)emmcnblocks() * Blen;
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
		q.path = Qdata;
		devdir(c, q, "sdcard", sdlength(), eve, 0640, dp);
		return 1;
	}
	i -= 2;
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
	if(!emmcpresent())
		error("no SD card");
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
	int boff;

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

		if(!iswrite){
			if(emmcread(blk, sd.buf) < 0)
				error(Eio);
			memmove(p + done, sd.buf + boff, m);
		}else{
			if(m != Blen){
				/* partial: keep what the caller did not send */
				if(emmcread(blk, sd.buf) < 0)
					error(Eio);
			}
			memmove(sd.buf + boff, p + done, m);
			if(emmcwrite(blk, sd.buf) < 0)
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
	if(i < 0 || i >= sd.npart)
		error(Ebadusefd);
	*base = sd.part[i].off;
	*len = sd.part[i].len;
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
			(vlong)emmcnblocks());
		for(i = 0; i < sd.npart && l < sizeof buf - 64; i++)
			l += snprint(buf+l, sizeof buf - l, "part %s %lld %lld\n",
				sd.part[i].name, sd.part[i].off / Blen,
				sd.part[i].len / Blen);
		return readstr(off, a, n, buf);
	}

	sdrange(c, &base, &len);
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
				strtoll(cb->f[3], nil, 0));
		else
			error(Ebadctl);
		poperror();
		free(cb);
		return n;
	}

	sdrange(c, &base, &len);
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
