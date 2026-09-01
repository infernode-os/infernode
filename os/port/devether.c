/*
 * #l -- Ethernet, served from the kernel.
 *
 * WHY THIS EXISTS. The Ethernet data path used to live outside the
 * kernel: a Limbo driver read USB bulk endpoints and served the
 * /net/ether0 file tree over 9P, and os/ip mounted it like any other
 * client. That was this port's experiment in keeping device protocols
 * out of the kernel, and the experiment returned a number: every frame
 * paid for process handoffs, the Dis interpreter token, and a 9P
 * transaction -- about two milliseconds of fixed cost per message on a
 * wire whose frames cost thirty microseconds. Batching amortised it to
 * ~1MB/s in, ~2MB/s out, on hardware that can do tens. The fixed cost
 * IS the architecture, so the data path moves here, where a frame's
 * journey from the USB stack to os/ip is function calls.
 *
 * WHAT DELIBERATELY DID NOT MOVE. Bring-up stays in Limbo: bus
 * enumeration, RNDIS negotiation, the LAN78xx register dance (OTP MAC,
 * PHY, burst aggregation) all run exactly as before, and when the
 * device is ready the Limbo side hands the open endpoints over with
 * one ctl write. Discovery and policy in userspace, the moving of
 * bytes in the kernel -- the split the design principles actually ask
 * for, as opposed to the one we tried first.
 *
 * HOW THE HANDOFF WORKS. The Limbo driver closes its endpoint data
 * files (they are exclusive-open; devusb refuses a second opener) and
 * writes to any ctl file under #l/ether0:
 *
 *	bind <family> <mac> <mbps> <burst> <inpath> <outpath>
 *
 * e.g. "bind lan78xx b827ebca4c8e 100 16384 /usb/usb/ep3.0/data
 * /usb/usb/ep3.2/data". The paths are resolved with namec() IN THE
 * WRITER'S NAMESPACE -- the same trick os/ip's ethermedium uses with
 * kdial -- so this file needs to know nothing about where #u is bound,
 * and the kernel processes that then own the Chans never need a
 * namespace at all. The endpoints reached this way go through devusb's
 * read/write entry points as direct calls: all of devusb's endpoint
 * machinery is reused, none of its file layer is paid for.
 *
 * WHAT SITS ON TOP. os/port/netif.c serves the whole /net/ether0 tree
 * -- clone, addr, stats, and per-conversation data/ctl/type -- and
 * ethermedium's dial("/net/ether0!0x800") works against it unchanged,
 * because netif's ctl speaks the same "connect" protocol the Limbo
 * server spoke. Binding "#l" after /net is all the boot script owes it.
 *
 * THE FRAMING LIVES HERE TOO, and that is a change of position worth
 * being honest about: RNDIS and LAN78xx record formats were "device
 * protocol outside the kernel" until the crossings they forced became
 * the whole cost. They are transcribed from the Limbo driver, whose
 * comments carry the war stories; the wire facts are identical.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/netif.h"

enum {
	Maxframe	= 1514,		/* an Ethernet frame, header included */

	/* families: who wraps a frame for the wire */
	Frndis		= 0,
	Flan78xx	= 1,

	/* RNDIS: one 44-byte header per packet message */
	Rnishdr		= 44,
	Rnisdata	= 1,		/* REMOTE_NDIS_PACKET_MSG */

	/* LAN78xx: TX_CMD_A/B before a frame out, RX_CMD_A/B/C before one in */
	Ltxhdr		= 8,
	Lrxhdr		= 10,
	Ltxfcs		= 0x00400000,	/* TX_CMD_A: append FCS */
	Ltxlen		= 0x000FFFFF,	/* TX_CMD_A: frame length */
	Lrxlen		= 0x00003FFF,	/* RX_CMD_A: frame length */
	Lrxerr		= 0x00400000,	/* RX_CMD_A: receive error */

	Nfiles		= 8,		/* ipv4 + arp + ipv6 + spare sniffers */
	Qlimit		= 128*1024,	/* per-conversation input queue */
	Oqlimit		= 256*1024,	/* outbound, before writers block */

	/*
	 * Frames gathered into one bulk OUT. Sixteen is a TCP window's
	 * worth, the same figure the Limbo driver settled on; the
	 * batch is sized by how long the previous transfer takes, not
	 * by any timer, so a lone frame on a quiet link never waits.
	 */
	Txbatch		= 16,
};

typedef struct Ether Ether;
struct Ether {
	Netif	nif;		/* MUST be first: netif.c casts the pointer */

	QLock	bindlk;		/* one bind, ever */
	int	bound;

	int	family;
	long	burst;		/* how much one bulk IN may carry */
	Chan	*inchan;	/* the endpoints, held open forever */
	Chan	*outchan;

	Queue	*oq;		/* outbound frames, one Block each */
	uchar	*txbuf;
	long	ntxbuf;
	uchar	*rxbuf;
	long	nrxbuf;
	long	nacc;		/* bytes carried over between reads */
};

static Ether ether[1];

/*
 * Hand every open conversation that asked for this type a copy.
 *
 * The predicate is netif's own: type < 0 is a sniffer and sees
 * everything, a positive type sees its ethertype, and a conversation
 * that has not connected (type 0) sees nothing -- zero is not a value
 * the type field of a real frame can hold.
 *
 * qpass discards and says so when a reader has fallen a queue's worth
 * behind; that is the same drop any interface makes when a consumer
 * stalls, and TCP recovers. Counted, never silent.
 */
static void
etheriq(Ether *e, uchar *frame, int len)
{
	int i, t;
	Block *b;
	Netfile *f;
	Netif *nif;

	nif = &e->nif;
	nif->inpackets++;
	t = (frame[12]<<8) | frame[13];
	for(i = 0; i < nif->nfile; i++){
		f = nif->f[i];
		if(f == nil || f->in == nil)
			continue;
		if(f->type != t && f->type >= 0)
			continue;
		b = allocb(len);
		memmove(b->wp, frame, len);
		b->wp += len;
		if(qpass(f->in, b) < 0)
			nif->soverflows++;
	}
}

/*
 * The record walks, transcribed from the Limbo driver.
 *
 * Each returns how many bytes of the buffer it consumed -- 0 for "not
 * enough yet, read more", -1 for "this is not a record boundary" --
 * and points *fp/*lp at the frame inside the buffer when there is one.
 * A record can be consumed WITHOUT yielding a frame (an error bit, a
 * control message); that is not a malformed stream.
 */
static long
rndisunwrap(uchar *p, long n, uchar **fp, long *lp)
{
	long msglen, dataoff, datalen;

	*fp = nil;
	if(n < Rnishdr)
		return 0;
	if((p[0] | (p[1]<<8) | (p[2]<<16) | (p[3]<<24)) != Rnisdata)
		return -1;
	msglen = p[4] | (p[5]<<8) | (p[6]<<16) | (p[7]<<24);
	if(msglen < Rnishdr)
		return -1;
	if(msglen > n)
		return 0;
	/* DataOffset counts from byte 8 of the message, not its start */
	dataoff = 8 + (p[8] | (p[9]<<8) | (p[10]<<16) | (p[11]<<24));
	datalen = p[12] | (p[13]<<8) | (p[14]<<16) | (p[15]<<24);
	if(datalen < 14 || dataoff + datalen > n)
		return msglen;		/* consumed; no frame in it */
	*fp = p + dataoff;
	*lp = datalen;
	return msglen;
}

static long
lanunwrap(uchar *p, long n, int atend, uchar **fp, long *lp)
{
	long datalen, used;
	ulong cmda;

	*fp = nil;
	if(n < Lrxhdr)
		return 0;
	cmda = p[0] | (p[1]<<8) | (p[2]<<16) | ((ulong)p[3]<<24);
	datalen = cmda & Lrxlen;
	if(datalen < 14 || datalen > Maxframe)
		return -1;
	/*
	 * Records are padded to a four-byte boundary, and the missing-pad
	 * question is now DECIDABLE, which it was not before the DWC
	 * layer learned to end reads honestly.
	 *
	 * Reads ask for exactly one aggregation cap. A read that comes
	 * back SHORT ended at a real device pause -- a short packet or a
	 * NAK -- and there the device may legitimately have stopped
	 * after a final record without its padding: clamp, the record is
	 * complete. A read that comes back FULL is the device chopping
	 * its gathered stream at the cap; nothing ended, the pad is
	 * simply still in flight, and clamping here is how two stray pad
	 * bytes used to end up parsed as a header of garbage. The caller
	 * says which case this is.
	 */
	used = Lrxhdr + datalen;
	used += (4 - (used % 4)) % 4;
	if(Lrxhdr + datalen > n)
		return 0;
	if(used > n){
		if(!atend)
			return 0;	/* the pad is still in flight */
		used = n;
	}
	if(cmda & Lrxerr)
		return used;
	*fp = p + Lrxhdr;
	*lp = datalen;
	return used;
}

/*
 * Append one frame, wrapped for the device, to the transmit buffer.
 * Returns the new fill, or -1 if it does not fit.
 */
static long
wrap(Ether *e, uchar *frame, long len, long o)
{
	uchar *p;
	long pad;

	if(len > Maxframe)
		len = Maxframe;
	switch(e->family){
	case Frndis:
		if(o + Rnishdr + len > e->ntxbuf)
			return -1;
		p = e->txbuf + o;
		memset(p, 0, Rnishdr);
		p[0] = Rnisdata;
		p[4] = (Rnishdr+len);
		p[5] = (Rnishdr+len) >> 8;
		p[6] = (Rnishdr+len) >> 16;
		p[8] = Rnishdr - 8;	/* DataOffset, from byte 8 */
		p[12] = len;
		p[13] = len >> 8;
		memmove(p + Rnishdr, frame, len);
		return o + Rnishdr + len;
	case Flan78xx:
		pad = (4 - ((Ltxhdr + len) % 4)) % 4;
		if(o + Ltxhdr + len + pad > e->ntxbuf)
			return -1;
		p = e->txbuf + o;
		p[0] = len;
		p[1] = len >> 8;
		p[2] = ((len & Ltxlen) >> 16) | ((Ltxfcs >> 16) & 0xff);
		p[3] = Ltxfcs >> 24;
		p[4] = p[5] = p[6] = p[7] = 0;
		memmove(p + Ltxhdr, frame, len);
		memset(p + Ltxhdr + len, 0, pad);
		return o + Ltxhdr + len + pad;
	}
	return -1;
}

/*
 * The reader: one process, forever, moving bulk IN transfers into the
 * conversations.
 *
 * A read boundary is not a record boundary -- the endpoint delivers
 * maxpkt at a time and a read ends at the first short packet, so a
 * record can straddle two reads. What does not yet form a whole record
 * is kept and the next read lands after it; on a "-1" the whole
 * remainder is dropped, because a stream that has lost its framing
 * does not resynchronise by optimism.
 */
static void
etherrxproc(void *a)
{
	Ether *e;
	long n, used, flen, off;
	uchar *fp;

	e = a;
	if(waserror()){
		print("ether0: reader exits: %s\n", up->env->errstr);
		e->nif.link = 0;
		pexit("hangup", 1);
	}
	for(;;){
		if(e->nacc >= e->nrxbuf - e->burst)
			e->nacc = 0;	/* desynchronised; start over */
		/*
		 * Exactly one aggregation cap per read. Ask for more and a
		 * transfer that fills the cap completes by LENGTH, with no
		 * short packet for the read layer to stop at -- the read
		 * runs on into the next transfer and glues them together.
		 * Ask for exactly the cap and every read ends at one of
		 * three honest places: the cap (stream chopped, more
		 * coming), a short packet, or a NAK pause (both real
		 * boundaries). That distinction is what lanunwrap's atend
		 * decides the missing-pad question with.
		 */
		n = kchanio(e->inchan, e->rxbuf + e->nacc, e->burst, OREAD);
		if(n < 0)
			error(Ehungup);
		if(n == 0){
			/*
			 * Nothing waiting. On real hardware bulk IN blocks
			 * until there is (the device NAKs and the
			 * controller retries); QEMU's model answers empty
			 * immediately, and a spin here would burn the one
			 * core everything shares. One tick, then ask again.
			 */
			tsleep(&up->sleep, return0, nil, 1);
			continue;
		}
		e->nacc += n;
		off = 0;
		for(;;){
			used = e->family == Frndis ?
				rndisunwrap(e->rxbuf+off, e->nacc-off, &fp, &flen) :
				lanunwrap(e->rxbuf+off, e->nacc-off,
					n < e->burst, &fp, &flen);
			if(used == 0)
				break;
			if(used < 0){
				e->nif.frames++;
				off = e->nacc;	/* drop the remainder */
				break;
			}
			if(fp != nil)
				etheriq(e, fp, flen);
			off += used;
			if(off >= e->nacc)
				break;
		}
		if(off > 0 && off < e->nacc)
			memmove(e->rxbuf, e->rxbuf+off, e->nacc-off);
		e->nacc -= off;
	}
}

/*
 * The writer: drains the outbound queue into bulk OUT transfers.
 *
 * qbread blocks until there is a frame, then qget gathers -- without
 * blocking -- whatever else arrived while the previous transfer was in
 * flight. The batch is therefore sized by how long the device takes
 * and nothing else, which is the same discipline the Limbo driver
 * arrived at: a lone frame on an idle link waits for nothing.
 */
static void
ethertxproc(void *a)
{
	Ether *e;
	Block *b;
	long o, no;
	int nf;

	e = a;
	if(waserror()){
		print("ether0: writer exits: %s\n", up->env->errstr);
		e->nif.link = 0;
		pexit("hangup", 1);
	}
	for(;;){
		b = qbread(e->oq, Maxframe+18);
		if(b == nil)
			error(Ehungup);
		o = 0;
		nf = 0;
		for(;;){
			no = wrap(e, b->rp, BLEN(b), o);
			freeb(b);
			if(no < 0)
				break;	/* full: send what is packed */
			o = no;
			nf++;
			if(nf >= Txbatch)
				break;
			b = qget(e->oq);
			if(b == nil)
				break;
		}
		if(o > 0){
			if(kchanio(e->outchan, e->txbuf, o, OWRITE) != o)
				e->nif.oerrs++;
			e->nif.outpackets += nf;
		}
	}
}

static int
parsemac(uchar *to, char *from)
{
	int i, c, hi, lo;

	for(i = 0; i < 6; i++){
		c = from[2*i];
		if(c >= '0' && c <= '9') hi = c - '0';
		else if(c >= 'a' && c <= 'f') hi = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F') hi = c - 'A' + 10;
		else return -1;
		c = from[2*i+1];
		if(c >= '0' && c <= '9') lo = c - '0';
		else if(c >= 'a' && c <= 'f') lo = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F') lo = c - 'A' + 10;
		else return -1;
		to[i] = (hi<<4) | lo;
	}
	return from[12] == 0 ? 0 : -1;
}

/*
 * The handoff: "bind <family> <mac> <mbps> <burst> <inpath> <outpath>".
 *
 * Runs in the writing process, deliberately -- namec resolves the
 * endpoint paths in ITS namespace, where #u is bound, and the Chans it
 * returns are then owned here and lent to processes that have no
 * namespace at all. The writer must have CLOSED its own opens of these
 * files first: devusb endpoints are exclusive-open, which is also what
 * guarantees the old data path and this one can never both be attached.
 */
static void
etherbindctl(Ether *e, char *args)
{
	char *f[8];
	int nf, family;
	long burst;
	Chan *in, *out;

	nf = getfields(args, f, nelem(f), 1, " \t\n");
	if(nf != 7)
		error(Ebadarg);
	if(strcmp(f[1], "rndis") == 0)
		family = Frndis;
	else if(strcmp(f[1], "lan78xx") == 0)
		family = Flan78xx;
	else
		error(Ebadarg);

	qlock(&e->bindlk);
	if(waserror()){
		qunlock(&e->bindlk);
		nexterror();
	}
	if(e->bound)
		error(Einuse);

	if(parsemac(e->nif.addr, f[2]) < 0)
		error(Ebadarg);
	e->nif.alen = 6;
	e->nif.mbps = atoi(f[3]);
	burst = atoi(f[4]);
	if(burst < 2*1024)
		burst = 2*1024;
	if(burst > 64*1024)
		burst = 64*1024;

	if(waserror()){
		print("ether0: open %s: %s\n", f[5], up->env->errstr);
		nexterror();
	}
	in = namec(f[5], Aopen, OREAD, 0);
	poperror();
	if(waserror()){
		cclose(in);
		print("ether0: open %s: %s\n", f[6], up->env->errstr);
		nexterror();
	}
	if(strcmp(f[5], f[6]) == 0)
		out = in;	/* one bidirectional endpoint */
	else
		out = namec(f[6], Aopen, OWRITE, 0);
	poperror();

	e->family = family;
	e->burst = burst;
	e->inchan = in;
	e->outchan = out;
	/* room for one gathered transfer plus a record straddling out of it */
	e->nrxbuf = burst + 2*(Rnishdr + Maxframe);
	e->rxbuf = smalloc(e->nrxbuf);
	e->ntxbuf = Txbatch * (Rnishdr + Maxframe + 4);
	e->txbuf = smalloc(e->ntxbuf);
	e->nacc = 0;
	e->nif.link = 1;
	e->bound = 1;

	kproc("ether0rx", etherrxproc, e, 0);
	kproc("ether0tx", ethertxproc, e, 0);

	qunlock(&e->bindlk);
	poperror();
	print("ether0: kernel data path bound (%s, %d mbps, burst %ld)\n",
		f[1], e->nif.mbps, burst);
}

static void
etherreset(void)
{
	netifinit(&ether[0].nif, "ether0", Nfiles, Qlimit);
	ether[0].oq = qopen(Oqlimit, 0, nil, nil);
	if(ether[0].oq == nil)
		panic("devether: no memory for the output queue");
}

static Chan*
etherattach(char *spec)
{
	return devattach('l', spec);
}

static Walkqid*
etherwalk(Chan *c, Chan *nc, char **name, int nname)
{
	return netifwalk(&ether[0].nif, c, nc, name, nname);
}

static int
etherstat(Chan *c, uchar *dp, int n)
{
	return netifstat(&ether[0].nif, c, dp, n);
}

static Chan*
etheropen(Chan *c, int omode)
{
	return netifopen(&ether[0].nif, c, omode);
}

static void
etherclose(Chan *c)
{
	netifclose(&ether[0].nif, c);
}

static long
etherread(Chan *c, void *buf, long n, vlong off)
{
	return netifread(&ether[0].nif, c, buf, n, off);
}

static Block*
etherbread(Chan *c, long n, ulong offset)
{
	return netifbread(&ether[0].nif, c, n, offset);
}

static long
etherwrite(Chan *c, void *buf, long n, vlong off)
{
	Ether *e;
	Block *b;
	char *s;
	long r;

	USED(off);
	e = &ether[0];
	if((c->qid.type & QTDIR) == 0)
	switch(NETTYPE(c->qid.path)){
	case Ndataqid:
		if(!e->bound)
			error(Enodev);
		if(n > Maxframe)
			error(Etoobig);
		b = allocb(n);
		memmove(b->wp, buf, n);
		b->wp += n;
		qbwrite(e->oq, b);
		return n;
	case Nctlqid:
		/*
		 * Accepted and ignored, as the Limbo server it replaces
		 * accepted and ignored it: ethermedium asks every ether
		 * ctl for "nonblocking", and nothing here blocks a client
		 * that this could switch off -- reads come out of queues,
		 * writes go into one. Rejecting it unwinds the whole
		 * ipifc bind, which is a large price for a word.
		 */
		if(n >= 11 && strncmp(buf, "nonblocking", 11) == 0)
			return n;
		if(n > 5 && strncmp(buf, "bind ", 5) == 0){
			s = malloc(n+1);
			if(s == nil)
				error(Enomem);
			if(waserror()){
				free(s);
				nexterror();
			}
			memmove(s, buf, n);
			s[n] = 0;
			etherbindctl(e, s);
			poperror();
			free(s);
			return n;
		}
		break;
	}
	r = netifwrite(&e->nif, c, buf, n);
	if(r < 0)
		error(Ebadctl);
	return r;
}

static long
etherbwrite(Chan *c, Block *bp, ulong offset)
{
	Ether *e;
	long n;

	e = &ether[0];
	if((c->qid.type & QTDIR) == 0 && NETTYPE(c->qid.path) == Ndataqid){
		if(!e->bound){
			freeb(bp);
			error(Enodev);
		}
		n = BLEN(bp);
		/*
		 * The Block goes onto the queue as it is -- no copy. This
		 * is the call os/ip's etherbwrite makes for every outbound
		 * frame, so it is the one worth keeping cheap.
		 */
		qbwrite(e->oq, bp);
		return n;
	}
	return devbwrite(c, bp, offset);
}

static int
etherwstat(Chan *c, uchar *dp, int n)
{
	return netifwstat(&ether[0].nif, c, dp, n);
}

Dev etherdevtab = {
	'l',
	"ether",

	etherreset,
	devinit,
	devshutdown,
	etherattach,
	etherwalk,
	etherstat,
	etheropen,
	devcreate,
	etherclose,
	etherread,
	etherbread,
	etherwrite,
	etherbwrite,
	devremove,
	etherwstat,
};
