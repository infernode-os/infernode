/*
 * VideoCore mailbox, property channel.
 *
 * The GPU owns most of the interesting hardware on this SoC -- clocks,
 * power, and crucially the display -- and the ARM asks for it by posting
 * a tagged message to mailbox channel 8 and waiting for it to come back
 * marked done.
 *
 * This is what makes the official 7in DSI panel tractable without a line
 * of DSI code: the firmware brings the panel up itself and switches the
 * framebuffer over to it, so a plain framebuffer request lands on the
 * display whatever it is plugged into.
 *
 * Two constraints the hardware will not forgive:
 *   - the message must be 16-byte aligned, because the low 4 bits of the
 *     word written to the mailbox are the channel number;
 *   - the GPU must be given a bus address, not an ARM physical one.
 *
 * Caches are off at this point, so no cache maintenance is needed around
 * the buffer.  That changes the moment the MMU comes up, and this comment
 * is the reminder.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

#define MBOX(r)	(*(volatile u32int*)((uintptr)MBOXREGS + (r)))

/*
 * Shared request buffer.  Single-threaded for now; when there is a
 * scheduler this needs a lock.
 *
 * volatile is load-bearing, not decoration.  Until the MMU is up, ARMv8
 * treats all memory as Device-nGnRnE, which forbids unaligned access --
 * and at -O2 the compiler will happily merge two adjacent 32-bit stores
 * into one 64-bit store.  The tag layout puts values at offset 20 from a
 * 16-byte-aligned base, which is 4-byte but not 8-byte aligned, so a
 * merged store there takes an alignment fault.  volatile forbids the
 * merge.  (It is also simply true: the GPU reads this buffer.)
 *
 * When the MMU comes up and this memory is mapped Normal rather than
 * Device, unaligned accesses become legal and the constraint relaxes --
 * but the buffer stays volatile because it really is shared.
 */
static volatile u32int mboxbuf[64] __attribute__((aligned(16)));

static void
dsb(void)
{
	__asm__ volatile("dsb sy" ::: "memory");
}

enum
{
	/*
	 * Generous: the firmware can take milliseconds to service a
	 * property call, and this is a bare loop on a 1.4GHz core. The
	 * point is to fail eventually with a message, not to be precise.
	 */
	Mboxspin = 100*1000*1000,

	/* every caller hands mboxcall the one shared buffer */
	Mboxbufsize = 64 * sizeof(u32int),
};

/*
 * Post the buffer to a channel and wait for the reply.  Returns 0 on
 * success, -1 if the firmware rejected the request.
 */
static int
mboxcall(u32int chan, volatile u32int *buf)
{
	u32int v, want;
	long i;

	want = (u32int)(BUSADDR(buf) & ~0xFUL) | (chan & 0xF);

	/*
	 * Clean the buffer out of the caches before the firmware reads it.
	 *
	 * BUSADDR sets 0xC0000000, the alias that BYPASSES the caches, and
	 * the VideoCore does not snoop the ARM's L1/L2 in any case. So the
	 * firmware reads RAM directly, and anything still sitting dirty in
	 * our cache is invisible to it -- it sees whatever was at those
	 * addresses before. dsb() does not help: it orders accesses, it
	 * does not push them to memory.
	 *
	 * Nothing here is modelled by QEMU, which has no caches at all, so
	 * this is invisible in emulation in both directions: a missing
	 * clean cannot fail there and a correct one cannot be shown to
	 * matter. It has to be reasoned about rather than tested.
	 *
	 * Whether it works without this depends on whether the lines
	 * happen to have been evicted, which is not a property a driver
	 * may rely on -- and would show up as calls that succeed early in
	 * boot and fail later, once more code has been through the cache.
	 */
	cachedwbse((void*)buf, Mboxbufsize);
	dsb();

	/*
	 * Bounded, because the firmware is another processor and it can
	 * decline to answer.
	 *
	 * Both of these waits were unbounded, and the outer loop below
	 * had no exit either: if no reply for our channel ever arrived,
	 * the kernel span here for ever with nothing printed. That is not
	 * a theoretical failure mode -- the mailbox is how memory size,
	 * board revision, the framebuffer and the USB power domain are
	 * obtained, so it runs before there is any other way to say what
	 * went wrong, and the symptom is a board that appears simply dead.
	 *
	 * Emulation cannot produce this: QEMU's firmware model always
	 * answers, and answers immediately. That is exactly why it needs
	 * bounding by inspection rather than by testing.
	 *
	 * A plain iteration count rather than a clock: this runs before
	 * clock initialisation.
	 */
	for(i = 0; MBOX(Mboxstatus) & Mboxfull; i++)
		if(i >= Mboxspin){
			uartputstr("mbox: full, firmware not draining\n");
			return -1;
		}
	MBOX(Mboxwrite) = want;

	/*
	 * Replies for other channels can in principle turn up here, so
	 * keep reading until one for ours arrives.
	 */
	for(i = 0;; i++){
		if(i >= Mboxspin){
			uartputstr("mbox: no reply for our channel\n");
			return -1;
		}
		if(MBOX(Mboxstatus) & Mboxempty)
			continue;
		v = MBOX(Mboxread);
		if((v & 0xF) == (chan & 0xF))
			break;
	}
	dsb();

	/*
	 * And discard them again before reading the reply, which the
	 * firmware wrote straight to RAM behind our caches.
	 *
	 * Clean-and-invalidate rather than invalidate alone is safe here
	 * only because the buffer was cleaned above and nothing has
	 * written to it since: the lines are clean, so the write-back half
	 * moves nothing and cannot put stale data back over the reply.
	 * That ordering is load-bearing -- doing this without the clean
	 * above would risk exactly the corruption it is meant to prevent.
	 */
	cachedwbinvse((void*)buf, Mboxbufsize);

	return buf[1] == Propok ? 0 : -1;
}

/*
 * Issue a single-tag property request.
 *
 * nreq words of request data are taken from data, and the tag's value
 * buffer is sized to the larger of the request and the expected reply so
 * that the firmware has room to answer in place.  On success the reply is
 * copied back into data.
 */
int
mboxprop(u32int tag, u32int *data, int nreq, int nresp)
{
	int i, nval;

	nval = nreq > nresp ? nreq : nresp;
	if(nval > 32)
		return -1;

	mboxbuf[0] = (nval + 6) * 4;	/* total size in bytes */
	mboxbuf[1] = Propreq;
	mboxbuf[2] = tag;
	mboxbuf[3] = nval * 4;		/* value buffer size */
	mboxbuf[4] = Propreq;		/* request; firmware ORs in Propok */

	for(i = 0; i < nreq; i++)
		mboxbuf[5 + i] = data[i];
	for(; i < nval; i++)
		mboxbuf[5 + i] = 0;

	mboxbuf[5 + nval] = Tagend;

	if(mboxcall(Mboxchanprop, mboxbuf) < 0)
		return -1;

	for(i = 0; i < nresp; i++)
		data[i] = mboxbuf[5 + i];

	return 0;
}

/*
 * Framebuffer allocation is one message with several tags: the firmware
 * applies them in order, so the dimensions and depth are set before the
 * allocate tag runs and the buffer comes back the right shape.  Splitting
 * these into separate calls is a classic way to get a black screen.
 */
int
mboxfballoc(u32int w, u32int h, u32int depth, Fbinfo *fb)
{
	volatile u32int *p, *tagalloc, *tagpitch;

	p = mboxbuf;
	*p++ = 0;			/* size, patched below */
	*p++ = Propreq;

	*p++ = Tagfbsetdim;   *p++ = 8; *p++ = Propreq; *p++ = w; *p++ = h;
	*p++ = Tagfbsetvdim;  *p++ = 8; *p++ = Propreq; *p++ = w; *p++ = h;
	*p++ = Tagfbsetvoff;  *p++ = 8; *p++ = Propreq; *p++ = 0; *p++ = 0;
	*p++ = Tagfbsetdepth; *p++ = 4; *p++ = Propreq; *p++ = depth;
	/*
	 * Pixel order 0 is BGR, 1 is RGB, and the names refer to BYTE
	 * order in memory, not to the layout of a 32-bit word.  Order 1
	 * puts red at the lowest address, so a little-endian load reads
	 * 0xAABBGGRR and a literal like 0xFF0000 comes out blue.  Order 0
	 * puts blue lowest, giving 0xAARRGGBB -- which is what everything
	 * else here assumes when it writes 0xRRGGBB.
	 */
	*p++ = Tagfbsetorder; *p++ = 4; *p++ = Propreq; *p++ = 0;	/* BGR bytes => 0xAARRGGBB */

	tagalloc = p;
	*p++ = Tagfballoc;    *p++ = 8; *p++ = Propreq;
	*p++ = 16;			/* requested alignment */
	*p++ = 0;			/* firmware returns size here */

	tagpitch = p;
	*p++ = Tagfbgetpitch; *p++ = 4; *p++ = Propreq; *p++ = 0;

	*p++ = Tagend;

	mboxbuf[0] = (u32int)((p - mboxbuf) * 4);

	if(mboxcall(Mboxchanprop, mboxbuf) < 0)
		return -1;

	fb->base = tagalloc[3] & 0x3FFFFFFF;	/* bus -> ARM physical */
	fb->size = tagalloc[4];
	fb->pitch = tagpitch[3];
	fb->width = w;
	fb->height = h;
	fb->depth = depth;

	if(fb->base == 0 || fb->pitch == 0)
		return -1;

	return 0;
}

/*
 * Turn a VideoCore power domain on or off.
 *
 * USB is powered down at reset, and a controller that has not been
 * powered on reads back as absent rather than as an error -- so
 * without this the driver simply reports no hardware.
 *
 * Powerwait asks the firmware not to return until the domain has
 * actually settled, which is what makes the call usable as a
 * precondition rather than a request.
 */
enum
{
	TagSetpower	= 0x00028001,
	Powerwait	= 1<<1,
	Powernodevice	= 1<<1,		/* in the RESPONSE: no such device */
};

int
setpower(int dev, int on)
{
	u32int buf[2];

	buf[0] = dev;
	buf[1] = Powerwait | (on ? 1 : 0);

	/*
	 * ELEMENT counts, not byte counts.
	 *
	 * mboxprop's nreq/nresp are u32int counts -- every other caller
	 * passes 0,1 or 0,2 -- and this passed sizeof buf, which is 8.
	 * The damage was threefold: the request declared a 32-byte value
	 * buffer for a tag the firmware expects to be 8, so the tag could
	 * be rejected outright; the copy in read 8 words from this
	 * 2-element array, six of them off the end; and the copy out
	 * wrote 8 words back into it, over six words of this function's
	 * stack frame.
	 *
	 * A USB block that was never actually powered explains what the
	 * board has been showing: registers that read back (they are not
	 * on the gated rail), a PHY too partly-initialised to complete a
	 * high-speed chirp -- hence a high-speed hub enumerating at full
	 * speed -- and channels that are accepted and never run.
	 *
	 * The result was also discarded, so none of this was visible.
	 */
	if(mboxprop(TagSetpower, buf, 2, 2) < 0){
		print("setpower: dev %d: property call failed\n", dev);
		return -1;
	}

	/*
	 * Report the reply rather than just a verdict.
	 *
	 * Bit 1 is Powerwait on the way in and "device does not exist" on
	 * the way back -- the same bit meaning two different things -- so
	 * a verdict derived from it is worth exactly as much as the
	 * assumption behind it. mboxbuf[4] carries the firmware's
	 * per-tag response word, which says whether the tag was
	 * processed at all.
	 */
	print("setpower: dev %d -> resp %8.8ux, dev %ud, state %8.8ux%s%s\n",
		dev, mboxbuf[4], buf[0], buf[1],
		buf[1] & 1 ? " ON" : " OFF",
		buf[1] & Powernodevice ? " NODEVICE" : "");

	if(buf[1] & Powernodevice)
		return -1;
	return (buf[1] & 1) == (on ? 1 : 0) ? 0 : -1;
}

/*
 * The board's Ethernet address, from the firmware.
 *
 * This part has no EEPROM and its OTP is unprogrammed, so the LAN7800
 * cannot say what its own address is -- the Pi's Ethernet address is
 * derived by the firmware from the board serial and handed to the
 * operating system. Linux receives it in the device tree as
 * local-mac-address; asking the mailbox directly gets the same answer
 * without needing to parse one.
 */
enum
{
	TagGetmac	= 0x00010003,
};

int
getmacaddr(uchar *mac)
{
	u32int v[2];

	v[0] = v[1] = 0;
	if(mboxprop(TagGetmac, v, 0, 2) < 0)
		return -1;

	/* six bytes, low word first, in wire order */
	mac[0] = v[0];
	mac[1] = v[0] >> 8;
	mac[2] = v[0] >> 16;
	mac[3] = v[0] >> 24;
	mac[4] = v[1];
	mac[5] = v[1] >> 8;
	return 0;
}
