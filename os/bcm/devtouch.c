#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"
#include "../port/error.h"

/*
 * #T: the DSI panel's touch buffer, as /dev/touch.
 *
 * The firmware polls the panel's FT5406 controller and keeps its
 * register block -- 64 bytes: mode, gesture, a point count and up to
 * ten 6-byte points -- in a buffer of its own choosing. This device
 * serves that buffer, and nothing else: one read-only file whose every
 * read is one whole snapshot, marked consumed as part of the read the
 * way the firmware expects (byte 2, the point count, set to 99; the
 * firmware overwrites it on its next poll).
 *
 * The byte layout is the panel's protocol and is decoded outside the
 * kernel, by os/init/touch.b, which turns it into events on
 * /dev/pointer. What stays in here is what a Limbo program cannot do:
 * issue the mailbox tags, translate the bus address the firmware
 * answers with, read memory that must be reached uncached, and keep the
 * cache honest when the buffer is ours.
 *
 * Two ways to find the buffer, tried at first attach, SET first (see
 * touchprobe):
 *
 *   GET (0x0004000F): the firmware allocated one. It lives in VideoCore
 *   memory above ramtop, which mmu.c maps Device-nGnRnE -- uncached, so
 *   no maintenance, but byte accesses only.
 *
 *   SET (0x0004801F): we hand the firmware a buffer of ours. That one
 *   is Normal cacheable memory, so it is invalidated before each read
 *   and cleaned after the consumed mark, or the firmware and the ARM
 *   would each see only their own writes.
 *
 * A panel is present when the firmware writes the buffer: after SET the
 * point count we planted is overwritten within a frame or two. Without
 * that, or with GET answering zero and SET not processed at all (QEMU
 * implements neither tag), there is no panel and the device refuses to
 * attach -- no panel, no file, the same rule #S applies to a missing
 * card.
 *
 * Readers are serialised by a lock but not made exclusive; see
 * touchopen() for why.
 */

enum{
	Qroot	= 0,
	Qtouch,

	Framelen	= 64,
	Consumed	= 99,
	Npoint		= 2,	/* byte holding the point count */
	Probems		= 200,	/* how long SET is given to show a live panel */
};

static Dirtab touchtab[] = {
	{".",		{Qroot, 0, QTDIR},	0,	DMDIR|0555},
	{"touch",	{Qtouch, 0, 0},		0,	0400},
};

static struct {
	QLock	lk;
	int	probed;
	volatile uchar *buf;	/* the frame, wherever it lives; nil = no panel */
	int	ours;		/* buf is setbuf: cache maintenance needed */
	u32int	bus;
} touch;

/*
 * The SET-path buffer. Cache-line aligned and a whole line long so the
 * maintenance below touches nothing else.
 */
static uchar setbuf[Framelen] __attribute__((aligned(64)));

/*
 * Wait for the firmware to overwrite a consumed mark: the one test that
 * says a panel is being polled into this buffer. Returns the number of
 * milliseconds it took, or -1.
 */
static int
touchlive(volatile uchar *buf, int ours)
{
	int i;

	for(i = 0; i < Probems/10; i++){
		microdelay(10000);
		if(ours)
			cachedwbinvse((void*)buf, Framelen);
		if(buf[Npoint] != Consumed)
			return (i+1)*10;
	}
	return -1;
}

static int
touchprobe(void)
{
	u32int v[1], getresp, getval, setresp;
	uintptr pa;
	int ms;

	if(touch.probed)
		return touch.buf != nil;
	touch.probed = 1;

	/*
	 * SET first. Current firmware polls the panel only into a buffer
	 * the driver hands it; GET can still answer with a buffer of the
	 * firmware's own that it no longer updates, and a driver that
	 * trusted GET first read the same stale frame forever. Either way
	 * the buffer is believed only once the firmware has been seen to
	 * write it.
	 */
	getresp = getval = setresp = 0;
	memset(setbuf, 0, Framelen);
	setbuf[Npoint] = Consumed;
	cachedwbse(setbuf, Framelen);
	v[0] = BUSADDR(setbuf);
	if(mboxprop(Tagsettouchbuf, v, 1, 1) == 0 && (mboxresp() & Propok)){
		setresp = mboxresp();
		ms = touchlive(setbuf, 1);
		if(ms >= 0){
			touch.buf = setbuf;
			touch.ours = 1;
			touch.bus = BUSADDR(setbuf);
			print("touch: buffer at bus %#8.8ux (set, ours; live after %dms, resp %#8.8ux)\n",
				touch.bus, ms, setresp);
			return 1;
		}
	}

	v[0] = 0;
	if(mboxprop(Taggettouchbuf, v, 1, 1) == 0){
		getresp = mboxresp();
		getval = v[0];
		if((getresp & Propok) && getval != 0){
			pa = getval & 0x3FFFFFFF;
			if(pa < mmuramtop()){
				/*
				 * Below ramtop the mapping is cacheable and a
				 * buffer the VideoCore writes would be read
				 * through stale lines. Not seen; refused
				 * rather than guessed at.
				 */
				print("touch: firmware buffer at bus %#8.8ux is below ramtop %#p; refusing\n",
					getval, (void*)mmuramtop());
			}else{
				((volatile uchar*)pa)[Npoint] = Consumed;
				ms = touchlive((volatile uchar*)pa, 0);
				if(ms >= 0){
					touch.buf = (volatile uchar*)pa;
					touch.ours = 0;
					touch.bus = getval;
					print("touch: buffer at bus %#8.8ux phys %#p (get; live after %dms, resp %#8.8ux)\n",
						getval, (void*)pa, ms, getresp);
					return 1;
				}
				print("touch: firmware buffer at bus %#8.8ux (get) is never written; stale\n", getval);
			}
		}
	}
	print("touch: no panel (set resp %#8.8ux%s; get resp %#8.8ux value %#ux)\n",
		setresp, setresp & Propok ? " accepted, never written" : "", getresp, getval);
	return 0;
}

static Chan*
touchattach(char *spec)
{
	if(!touchprobe())
		error("no touch panel");
	return devattach('T', spec);
}

static Walkqid*
touchwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, touchtab, nelem(touchtab), devgen);
}

static int
touchstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, touchtab, nelem(touchtab), devgen);
}

/*
 * Not exclusive. The first version refused a second opener so two
 * readers could not race each other for the consumed mark, and the
 * flag outlived its owner: on this kernel a killed process's files
 * are not closed promptly, so after the driver was killed the device
 * answered "in use" to everyone with no process holding it, and the
 * one time the raw frame was needed for diagnosis it could not be
 * read without a reboot. A second reader costs the first some frames;
 * a flag nobody can clear costs the panel. Reads are still serialised
 * by the lock, so a frame is never torn by two readers at once.
 */
static Chan*
touchopen(Chan *c, int omode)
{
	if(c->qid.path == Qtouch && omode != OREAD)
		error(Eperm);
	return devopen(c, omode, touchtab, nelem(touchtab), devgen);
}

static void
touchclose(Chan *c)
{
	USED(c);
}

/*
 * One snapshot per read, offset ignored: an event file, like
 * /dev/pointer. A read too short for a whole frame is refused rather
 * than delivered in part, because the frame is consumed by being read.
 */
static long
touchread(Chan *c, void *a, long n, vlong off)
{
	uchar *p;
	int i;

	USED(off);
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, touchtab, nelem(touchtab), devgen);
	if(n < Framelen)
		error(Etoosmall);

	qlock(&touch.lk);
	if(waserror()){
		qunlock(&touch.lk);
		nexterror();
	}
	if(touch.ours)
		cachedwbinvse(setbuf, Framelen);
	p = a;
	for(i = 0; i < Framelen; i++)
		p[i] = touch.buf[i];
	touch.buf[Npoint] = Consumed;
	if(touch.ours)
		cachedwbse(setbuf, Framelen);
	poperror();
	qunlock(&touch.lk);
	return Framelen;
}

static long
touchwrite(Chan *c, void *a, long n, vlong off)
{
	USED(c); USED(a); USED(n); USED(off);
	error(Eperm);
	return 0;
}

Dev touchdevtab = {
	'T',
	"touch",

	devreset,
	devinit,
	devshutdown,
	touchattach,
	touchwalk,
	touchstat,
	touchopen,
	devcreate,
	touchclose,
	touchread,
	devbread,
	touchwrite,
	devbwrite,
	devremove,
	devwstat,
};
