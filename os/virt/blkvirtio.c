/*
 * The disk: a virtio block device, as the blocks under #S.
 *
 * On the board #S is the SD card, and devsd.c -- which knows nothing
 * about cards, only that something below it moves 512-byte blocks --
 * asks four things of that something: is it there, how big is it, read
 * block n, write block n. This file answers the same four for a file
 * on the host:
 *
 *	-drive file=card.img,if=none,format=raw,id=sd
 *	-device virtio-blk-device,drive=sd
 *
 * so that the image written to a Raspberry Pi's card and the image this
 * machine boots from are THE SAME FILE, and everything above the blocks
 * -- the partition names init writes to sdctl, dossrv reading FAT out
 * of /dev/sdcard, the desktop coming off the card -- runs here
 * unmodified. That is most of what this port is for.
 *
 * (-device virtio-blk-device, not -drive if=virtio: the latter makes a
 * PCI device, on a bus this kernel does not walk.)
 *
 * A request is three buffers chained through the queue: a sixteen-byte
 * header the device reads (read or write, which sector), the data, and
 * one status byte the device writes. One request at a time, under a
 * QLock, which is what devsd.c does above this anyway; QEMU answers in
 * tens of microseconds and nothing here is worth a second in flight
 * until something measures otherwise.
 *
 * The wait is an interrupt and a sleep when there is a process to put
 * to sleep, and a poll when there is not -- the boot path touches the
 * disk before the scheduler is running, as the board's does.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "board.h"
#include "virtio.h"

enum
{
	Blen		= 512,

	/* request types */
	Blkin		= 0,		/* device to guest: a read */
	Blkout		= 1,

	/* the status byte */
	Blkok		= 0,
	Blkioerr	= 1,
	Blkunsupp	= 2,

	/* feature bits */
	Blkfro		= 1ULL<<5,	/* the host opened the file read-only */

	Blkpollus	= 5000000,	/* a polled request's patience */
};

typedef struct Blkhdr Blkhdr;
struct Blkhdr
{
	u32int	type;
	u32int	reserved;
	u64int	sector;
};

static struct
{
	QLock	q;
	Vdev	*dev;
	Vq	*vq;
	Rendez	r;
	int	done;		/* the interrupt has seen a completion */
	int	ro;
	uvlong	nblocks;
	ulong	nread, nwrite, nintr, npolled;

	/* what the device reads and writes besides the data; never the stack */
	Blkhdr	hdr;
	uchar	status;
} blk;

static void
blkinterrupt(Ureg*, void*)
{
	if(virtiointr(blk.dev) & 1){
		blk.nintr++;
		blk.done = 1;
		wakeup(&blk.r);
	}
}

static int
blkisdone(void*)
{
	return blk.done;
}

/*
 * Called from boarddevprobe. Finds the first virtio disk on QEMU's
 * command line; a machine started without one simply has no #S, like a
 * board with no card in it.
 */
void
blkvirtioinit(void)
{
	uchar cap[8];
	int i;

	blk.dev = virtiofind(Vidblk, 0);
	if(blk.dev == nil){
		print("blk:  no virtio disk; #S will not attach\n");
		return;
	}
	if(virtiostart(blk.dev, Blkfro) < 0
	|| (blk.vq = virtioqueue(blk.dev, 0, 16)) == nil){
		blk.dev = nil;
		return;
	}
	blk.ro = (blk.dev->features & Blkfro) != 0;

	/* capacity: the first eight bytes of the configuration, in 512-byte sectors */
	virtiocfgread(blk.dev, 0, cap, 8);
	blk.nblocks = 0;
	for(i = 7; i >= 0; i--)
		blk.nblocks = blk.nblocks<<8 | cap[i];

	intrenable(blk.dev->irq, blkinterrupt, nil, 0, "virtio-blk");
	virtioready(blk.dev);
	print("blk:  virtio disk, %llud blocks (%lludMB)%s\n",
		blk.nblocks, blk.nblocks*Blen >> 20, blk.ro ? ", READ-ONLY" : "");
}

int
sdblkpresent(void)
{
	return blk.dev != nil;
}

uvlong
sdblknblocks(void)
{
	return blk.nblocks;
}

static int
blkrequest(int type, uvlong blkno, void *buf)
{
	Vbuf b[3];
	int waited;

	if(blk.dev == nil || blkno >= blk.nblocks)
		return -1;
	if(type == Blkout && blk.ro)
		return -1;

	qlock(&blk.q);
	blk.hdr.type = type;
	blk.hdr.reserved = 0;
	blk.hdr.sector = blkno;
	blk.status = 0xFF;		/* neither OK nor any error: "untouched" */

	b[0].p = &blk.hdr;
	b[0].len = sizeof blk.hdr;
	b[0].write = 0;
	b[1].p = buf;
	b[1].len = Blen;
	b[1].write = type == Blkin;
	b[2].p = &blk.status;
	b[2].len = 1;
	b[2].write = 1;

	blk.done = 0;
	if(vqsubmit(blk.vq, b, 3, nil) < 0){
		qunlock(&blk.q);
		return -1;
	}
	vqkick(blk.vq);

	if(up != nil && islo()){
		/*
		 * tsleep, and look at the ring whatever woke us: a lost
		 * interrupt then costs a second, once, and is visible in
		 * the count below rather than being a hang.
		 */
		while(vqcollect(blk.vq, nil, nil) < 0){
			tsleep(&blk.r, blkisdone, nil, 1000);
			blk.done = 0;
		}
	}else{
		blk.npolled++;
		for(waited = 0; vqcollect(blk.vq, nil, nil) < 0; waited += 20){
			if(waited >= Blkpollus){
				qunlock(&blk.q);
				return -1;
			}
			microdelay(20);
		}
		virtiointr(blk.dev);
	}

	if(type == Blkin)
		blk.nread++;
	else
		blk.nwrite++;
	waited = blk.status;
	qunlock(&blk.q);
	return waited == Blkok ? 0 : -1;
}

int
sdblkread(uvlong blkno, void *buf)
{
	return blkrequest(Blkin, blkno, buf);
}

int
sdblkwrite(uvlong blkno, void *buf)
{
	return blkrequest(Blkout, blkno, buf);
}
