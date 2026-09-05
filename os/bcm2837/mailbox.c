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
 * Shared request buffer, one for the whole kernel, guarded by mboxmutex
 * below -- see there for why it is the shape of lock it is.
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

/*
 * One buffer, therefore one lock -- and it is the BUFFER that is
 * protected, not just the exchange with the firmware.
 *
 * Every caller fills mboxbuf, posts it, and reads the reply back out of
 * it. Two callers at once interleave their requests into it and both
 * get an answer to a question neither asked. That is routine now, not
 * hypothetical: the framebuffer console moves the scanout window
 * through here on every scroll, from whatever process is printing on
 * whatever core, while draw and the pointer run on the others. So the
 * lock is held from the first word written to the last word read; an
 * earlier version took it around the post-and-wait alone and left
 * mboxfballoc reading its tags, and setpower its response word, out of
 * a buffer the next caller was free to overwrite.
 *
 * Not lock() and not ilock(), but the bounded _tas mutex fbcons and the
 * uart use, held with interrupts off. The reasons, in order:
 *
 *   - the print path reaches here from INTERRUPT AND PANIC CONTEXT.
 *     panic() is putstrn(), which is screenputs(), which scrolls the
 *     console, which is a mailbox call; a trap handler that print()s
 *     does the same. lock() spinning at splhi on a mutex whose holder
 *     is the process this very core interrupted can never see it
 *     released, and ends in lockloop(), which panics, which prints,
 *     which takes the lock: the message that mattered is lost in the
 *     recursion. The old comment here rested on iprint never reaching
 *     the screen, and overlooked that panic does not use iprint.
 *   - holding it with interrupts OFF is what rules the same-core case
 *     out: a holder cannot be interrupted, so no interrupt-time print
 *     on its core can arrive while it holds. What remains is another
 *     core, which releases within one call's time, or a holder that
 *     took an exception inside the call -- and that is the panic path.
 *   - so the wait is bounded, and a waiter that times out proceeds
 *     anyway, unlocked, and says so on the uart. The only way to reach
 *     that is a holder that will never release (a dead core, an
 *     exception mid-call, a firmware that stopped answering), and for a
 *     panic message garbled beats silent. A waiter that arrives with
 *     interrupts on spins with them on, so waiting costs nothing but
 *     this core's time.
 *
 * Interrupts off while HELD means a call the firmware never answers
 * keeps them off for the Mboxspin bound, on one core, once. The
 * previous version avoided that in exchange for the recursion above;
 * the trade is deliberate. A stalled mailbox is the display, the USB
 * power domain and the memory map, and everything else happening on
 * the machine then is the failure being reported.
 *
 * A per-caller buffer was the other way out and was rejected: the
 * mailbox FIFO matches replies to channels, not to buffers, so two
 * requests in flight on the property channel hand each other their
 * answers whatever memory they came from. Separate buffers would move
 * the corruption from the message to the reply, not remove it.
 */
static ulong mboxmutex;
static int mboxlockable;

typedef struct Mboxhold Mboxhold;
struct Mboxhold
{
	int	spl;		/* interrupt state to put back */
	int	held;		/* the mutex is ours to release */
};

enum
{
	/*
	 * In 10us steps: two seconds. An answered mailbox call takes
	 * microseconds to tens of milliseconds, so a holder still there
	 * after this is not coming back, and the waiter is better off
	 * corrupting one exchange than waiting for ever with interrupts
	 * off. Sized against the fbcons scroll-fold, the longest legitimate
	 * hold on the console path, with a wide margin.
	 */
	Mboxlockwait = 200*1000,
};

/*
 * Start locking. Called once the MMU is on.
 *
 * NOT an optimisation -- taking the lock before this point FAULTS. A
 * mutex is acquired with load-exclusive/store-exclusive, and exclusive
 * accesses are only architecturally supported on Normal memory with the
 * MMU enabled; with it off the core takes a data abort (ESR ...0x35,
 * the unsupported-exclusive fault) on the first one. The very first
 * mailbox call reads the board revision and the memory size, and it has
 * to happen BEFORE the MMU because the MMU tables are sized from what
 * it returns.
 *
 * Nothing is lost by waiting: until the scheduler exists there is one
 * thread of control, so there is nothing to serialise against.
 *
 * The emulator does not care -- QEMU permits exclusives with the MMU
 * off -- so this could only ever have been found on the board.
 */
void
mboxlockon(void)
{
	mboxlockable = 1;
}

static void
mboxacquire(Mboxhold *h)
{
	int i;

	h->held = 0;
	h->spl = 0;
	if(!mboxlockable)
		return;
	for(i = 0; i < Mboxlockwait; i++){
		h->spl = splhi();
		if(_tas(&mboxmutex) == 0){
			h->held = 1;
			return;
		}
		splx(h->spl);
		microdelay(10);
	}
	/*
	 * The holder is not coming back. Go in anyway, with interrupts
	 * off like a holder would have them, and leave the mutex to whoever
	 * does own it: clearing it here would let a THIRD caller in on top
	 * of both of us.
	 */
	uartputstr("mbox: lock held too long; proceeding unlocked\n");
	h->spl = splhi();
}

static void
mboxrelease(Mboxhold *h)
{
	if(!mboxlockable)
		return;
	if(h->held){
		coherence();
		mboxmutex = 0;
	}
	splx(h->spl);
}

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
	Maxvalwords = 64 - 8,	/* room for the header, the tag and Tagend */
	Cmdlinewords = Mboxcmdlinemax / 4,	/* the value buffer; see mboxcmdline */
};

/*
 * Post the buffer to a channel and wait for the reply.  Returns 0 on
 * success, -1 if the firmware rejected the request.
 *
 * The caller holds the mutex (mboxacquire) for the whole of fill, post
 * and copy-out; this does the middle third.
 */
/*
 * size is the buffer's length in bytes: the cache maintenance below
 * has to cover the whole of what the firmware will read and write, and
 * the command line needs a buffer four times the size of mboxbuf.
 */
static int
mboxcall(u32int chan, volatile u32int *buf, int size)
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
	cachedwbse((void*)buf, size);
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
	cachedwbinvse((void*)buf, size);

	return buf[1] == Propok ? 0 : -1;
}

/* the buffer lock, for a caller that fills and reads mboxbuf itself */
/*
 * Issue a single-tag property request.
 *
 * nreq words of request data are taken from data, and the tag's value
 * buffer is sized to the larger of the request and the expected reply so
 * that the firmware has room to answer in place.  On success the reply is
 * copied back into data, and the tag's own response word -- the length
 * the firmware wrote, with Propok set if it understood the tag -- into
 * *tagresp if that is not nil.
 *
 * The mutex is held from the first word written to the last word read,
 * NOT only around the mailbox exchange. mboxbuf is one buffer, and a
 * caller that reads the reply out of it after the exchange has been
 * released reads whatever the next caller has by then written there.
 * That next caller is routine: the framebuffer console makes a mailbox
 * call on every scroll, from whichever process is printing, so a reply
 * read late could be a scroll offset's. The first reader of the tag
 * response word (mboxreboot) did exactly that, and the line it prints
 * is the board evidence the README asks for, so it had to be made true.
 */
/*
 * The firmware's per-tag response word from the last property call.
 * mboxprop() cannot tell an unimplemented tag from success -- the
 * message as a whole succeeds either way -- so a caller that must
 * distinguish "the firmware says no" from "the firmware never looked"
 * reads this: Propok set means the tag was processed.
 */
u32int
mboxresp(void)
{
	return mboxbuf[4];
}

int
mboxprop1(u32int tag, u32int *data, int nreq, int nresp, u32int *tagresp)
{
	Mboxhold h;
	int i, nval, r;

	nval = nreq > nresp ? nreq : nresp;
	/*
	 * 56, not 32. An EDID block alone is 34 words of value buffer,
	 * and mboxbuf holds 64 -- six of which are the message header and
	 * the end tag. The old limit was conservative rather than
	 * derived, and refused a request that fits comfortably.
	 */
	if(nval > Maxvalwords)
		return -1;

	mboxacquire(&h);

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

	r = mboxcall(Mboxchanprop, mboxbuf, Mboxbufsize);
	if(r == 0){
		for(i = 0; i < nresp; i++)
			data[i] = mboxbuf[5 + i];
		if(tagresp != nil)
			*tagresp = mboxbuf[4];
	}

	mboxrelease(&h);
	return r;
}

int
mboxprop(u32int tag, u32int *data, int nreq, int nresp)
{
	return mboxprop1(tag, data, nreq, nresp, nil);
}

/*
 * The firmware's kernel command line: cmdline.txt as named by the
 * config.txt (or tryboot.txt) that was in force, plus whatever the
 * firmware appends of its own. Copied into buf as a NUL-terminated
 * string, truncated to n-1 bytes.
 *
 * The return is the length the firmware REPORTED, unclamped, or -1 if
 * the tag went unanswered. That number is the caller's to judge: if
 * it exceeds Mboxcmdlinemax the firmware copied nothing and buf is
 * empty -- the protocol's response to a value buffer that is too
 * short is to say how much it needed and write none of it -- and an
 * empty buf then means "unread", not "no command line". An earlier
 * version clamped the length to the buffer, so the two cases were
 * indistinguishable to the caller and an over-long line would have
 * booted a tryboot candidate with the watchdog unarmed, silently.
 *
 * A buffer of its own, four times mboxbuf. A real Pi's command line
 * runs to several hundred bytes -- the firmware adds vc_mem.mem_base,
 * the Ethernet MAC and the framebuffer geometry unasked -- and
 * through mboxprop's 224 bytes it would have read as "no command
 * line" on exactly the machines that have one. QEMU answers with
 * -append, so the whole path is testable there; the length problem
 * is not.
 */
static volatile u32int cmdlinebuf[8 + Cmdlinewords] __attribute__((aligned(16)));

int
mboxcmdline(char *buf, int n)
{
	Mboxhold h;
	int i, len;
	volatile uchar *p;

	cmdlinebuf[0] = (Cmdlinewords + 6) * 4;
	cmdlinebuf[1] = Propreq;
	cmdlinebuf[2] = Taggetcmdline;
	cmdlinebuf[3] = Mboxcmdlinemax;
	cmdlinebuf[4] = Propreq;
	for(i = 0; i < Cmdlinewords; i++)
		cmdlinebuf[5 + i] = 0;
	cmdlinebuf[5 + Cmdlinewords] = Tagend;

	buf[0] = 0;
	/*
	 * A private buffer, but the mailbox is one channel: the exchange
	 * itself is serialised by the same mutex as everyone else's.
	 */
	mboxacquire(&h);
	if(mboxcall(Mboxchanprop, cmdlinebuf, sizeof cmdlinebuf) < 0){
		mboxrelease(&h);
		return -1;
	}
	if((cmdlinebuf[4] & Propok) == 0){
		mboxrelease(&h);
		return -1;			/* the tag was not answered */
	}

	len = cmdlinebuf[4] & ~Propok;	/* the firmware's own length */
	if(len > Mboxcmdlinemax){
		mboxrelease(&h);
		return len;		/* it copied nothing; buf stays empty */
	}
	p = (volatile uchar*)&cmdlinebuf[5];
	for(i = 0; i < len && i < n - 1 && p[i] != 0; i++)
		buf[i] = p[i];
	buf[i] = 0;
	mboxrelease(&h);
	return len;
}

/*
 * Tell the firmware what the coming reset is for.
 *
 * With tryboot set, the boot after the reset -- and only that one --
 * takes its configuration from tryboot.txt, or from the [tryboot]
 * section of config.txt. The flag is the firmware's to keep: it is
 * asked for here, through the same tag Linux's reboot notifier uses,
 * and the kernel never learns where it is stored. NOTIFY_REBOOT is
 * what Linux sends next, always, flag or no flag.
 *
 * The check is on the TAG's response bit, not only the message's:
 * the message succeeds whenever the firmware parsed it, and what this
 * caller needs to know is whether this particular tag was understood.
 * QEMU's property model sets the bit for every tag it is handed,
 * known or not, so under emulation the answer is always yes and proves
 * only that the message was well formed. The board is where the
 * answer means something, and the line printed from it is the
 * evidence the README asks for.
 */
int
mboxreboot(int tryboot)
{
	u32int v[1], resp;
	int r;

	r = 0;
	v[0] = 0;
	if(tryboot){
		v[0] = Rebootflagtryboot;
		/*
		 * mboxprop1, for the tag response word: read under the
		 * mailbox mutex, so it is this tag's answer and not the
		 * next framebuffer scroll's.
		 */
		if(mboxprop1(Tagsetrebootflags, v, 1, 1, &resp) < 0 || (resp & Propok) == 0)
			r = -1;
	}
	if(mboxprop(Tagnotifyreboot, v, 0, 0) < 0)
		r = -1;
	return r;
}

/*
 * Framebuffer allocation is one message with several tags: the firmware
 * applies them in order, so the dimensions and depth are set before the
 * allocate tag runs and the buffer comes back the right shape.  Splitting
 * these into separate calls is a classic way to get a black screen.
 */
int
mboxfballoc(u32int disp, u32int w, u32int h, u32int depth, Fbinfo *fb)
{
	volatile u32int *p, *tagalloc, *tagpitch, *tagdisp;
	Mboxhold hold;

	/*
	 * Held until the tags have been read back: they are read out of
	 * the shared buffer, and a console scroll on another core between
	 * the call returning and the reads would replace them.
	 */
	mboxacquire(&hold);
	p = mboxbuf;
	*p++ = 0;			/* size, patched below */
	*p++ = Propreq;

	/*
	 * Choose the display FIRST, in this same message.
	 *
	 * Tags are processed in order, so selecting the display here is
	 * what makes every tag after it -- the dimensions, the depth, the
	 * allocation itself -- apply to that display rather than to
	 * whichever one the firmware happens to have made current. Sent
	 * as a separate call beforehand, the selection was simply
	 * refused: asking for display 1 returned 0.
	 *
	 * The firmware writes back the display it actually selected, so
	 * the caller can tell a granted request from an ignored one
	 * rather than assuming.
	 */
	tagdisp = p;
	*p++ = Tagfbsetdispnum; *p++ = 4; *p++ = Propreq; *p++ = disp;

	*p++ = Tagfbsetdim;   *p++ = 8; *p++ = Propreq; *p++ = w; *p++ = h;
	/*
	 * Twice as tall a VIRTUAL framebuffer as the display shows.
	 *
	 * The extra height is what makes scrolling free: the visible
	 * window is moved down it by setting an offset, which is a
	 * register the GPU reads, instead of moving 1.5MB of pixels
	 * through a bus the ARM reaches slowly. A console write on this
	 * board measured 990ms and every millisecond of it was the
	 * memmove.
	 *
	 * When the offset reaches the bottom the content is folded back
	 * to the top, which costs one move -- but once per screenful
	 * rather than once per line.
	 */
	*p++ = Tagfbsetvdim;  *p++ = 8; *p++ = Propreq; *p++ = w; *p++ = h * 2;
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

	if(mboxcall(Mboxchanprop, mboxbuf, Mboxbufsize) < 0){
		mboxrelease(&hold);
		return -1;
	}

	fb->disp = tagdisp[3];
	fb->base = tagalloc[3] & 0x3FFFFFFF;	/* bus -> ARM physical */
	fb->size = tagalloc[4];
	fb->pitch = tagpitch[3];
	mboxrelease(&hold);
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
	u32int buf[2], resp;

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
	resp = 0;
	if(mboxprop1(TagSetpower, buf, 2, 2, &resp) < 0){
		print("setpower: dev %d: property call failed\n", dev);
		return -1;
	}

	/*
	 * Report the reply rather than just a verdict.
	 *
	 * Bit 1 is Powerwait on the way in and "device does not exist" on
	 * the way back -- the same bit meaning two different things -- so
	 * a verdict derived from it is worth exactly as much as the
	 * assumption behind it. resp is the firmware's per-tag response
	 * word, which says whether the tag was processed at all -- taken
	 * from the shared buffer while it was still ours, not after.
	 */
	print("setpower: dev %d -> resp %8.8ux, dev %ud, state %8.8ux%s%s\n",
		dev, resp, buf[0], buf[1],
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

/*
 * Move the visible window within the virtual framebuffer.
 *
 * This is the whole point of allocating one taller than the screen: the
 * GPU is told where to start reading and does the rest. Nothing is
 * copied.
 *
 * Returns the offset the firmware actually GRANTED, which is not always
 * the one asked for -- a firmware with no virtual space to spare clamps
 * it to zero and reports success. Returning the granted value rather
 * than an error code is what lets the caller tell a working offset from
 * an accepted-and-ignored one, and fall back to copying pixels.
 */
int
mboxfbvoff(u32int x, u32int y)
{
	u32int buf[2];

	buf[0] = x;
	buf[1] = y;
	if(mboxprop(Tagfbsetvoff, buf, 2, 2) < 0){
		uartputstr("fb:   voff set FAILED\n");
		return -1;
	}
	/*
	 * Say so when the firmware grants something other than what was
	 * asked. Every caller used to discard this value, and one silent
	 * refusal -- the fold's move back to row zero -- left the panel
	 * scanning a stale window under a freshly painted login screen.
	 */
	if(buf[1] != y){
		uartputstr("fb:   voff asked ");
		uartputd(y);
		uartputstr(" granted ");
		uartputd(buf[1]);
		uartputstr("\n");
	}
	return (int)buf[1];
}

/*
 * What the GPU is ACTUALLY scanning from, asked of the firmware.
 *
 * This exists because trusting the software copy of the offset cost a
 * day: the console had scrolled the scanout window down, the reset at
 * draw-attach silently failed to move it back, and every software-side
 * check -- including the debug-key screen capture -- read the
 * framebuffer at offset zero and reported a login screen the glass was
 * not showing. The person at the panel was the only honest instrument
 * in the loop. Verification of what is on screen starts HERE.
 */
int
mboxfbgetvoff(void)
{
	u32int buf[2];

	buf[0] = 0;
	buf[1] = 0;
	if(mboxprop(Tagfbgetvoff, buf, 2, 2) < 0)
		return -1;
	return (int)buf[1];
}

/*
 * How many displays the firmware knows about.
 *
 * Returns 1 when it cannot say. An unimplemented tag comes back with the
 * response bit clear and a zero length, which mboxprop does not
 * distinguish from success, so a count of zero -- or an absurd one --
 * means "the firmware did not answer this", not "there are no displays".
 */
int
mboxfbnumdisplays(void)
{
	u32int buf[1];

	buf[0] = 0;
	if(mboxprop(Tagfbgetnumdisp, buf, 0, 1) < 0)
		return 1;
	if(buf[0] == 0 || buf[0] > 4)
		return 1;
	return (int)buf[0];
}

/*
 * Choose which display the framebuffer tags act on.
 *
 * Returns the display the firmware says it selected, which need not be
 * the one asked for.
 */
int
mboxfbdispnum(u32int n)
{
	u32int buf[1];

	buf[0] = n;
	if(mboxprop(Tagfbsetdispnum, buf, 1, 1) < 0)
		return -1;
	return (int)buf[0];
}

/*
 * The rate a peripheral clock is actually running at.
 *
 * Asked for rather than assumed: the EMMC base clock depends on what
 * the firmware negotiated for the core, which config.txt can change, so
 * a divider computed from a hardcoded base gives a card clock that is
 * wrong by whatever the user set. Returns 0 if the firmware will not
 * say, and the caller decides what to do about that.
 */
u32int
mboxclockrate(u32int id)
{
	u32int buf[2];

	buf[0] = id;
	buf[1] = 0;
	if(mboxprop(Taggetclockrate, buf, 1, 2) < 0)
		return 0;
	return buf[1];
}

/*
 * The most a clock will ever run at. A divider computed from the
 * momentary rate is wrong the moment the firmware scales the core
 * clock up under load, and the SDHOST is clocked from the core: the
 * card would be overclocked. Dividing the maximum instead gives a card
 * clock that is only ever slower than asked, which SD tolerates.
 */
u32int
mboxmaxclockrate(u32int id)
{
	u32int buf[2];

	buf[0] = id;
	buf[1] = 0;
	if(mboxprop(Taggetmaxclockrate, buf, 1, 2) < 0)
		return 0;
	return buf[1];
}

/*
 * Read one 128-byte EDID block from the display.
 *
 * This is how "is anything actually plugged in?" is answered. The
 * firmware reports the display COUNT whether or not a monitor is
 * attached, and hands out a fallback mode -- 720x480 with nothing on
 * the HDMI socket -- so counting displays and allocating for each one
 * means allocating a megabyte and a half of framebuffer that nobody
 * will ever see.
 *
 * EDID is the display's own description of itself, read over the
 * monitor's data channel. A display that is not there cannot answer,
 * which is exactly the distinction wanted. Note that a DSI panel has no
 * EDID either: it is not on a channel that carries one, so absence of
 * EDID means "no monitor on this connector", not "no display".
 *
 * Returns 0 and fills buf on success.
 */
int
mboxedid(u32int block, uchar *buf)
{
	u32int v[34];
	int i;

	memset(v, 0, sizeof v);
	v[0] = block;
	if(mboxprop(Taggetedidblock, v, 1, nelem(v)) < 0)
		return -1;
	if(v[1] != 0)			/* status: 0 is success */
		return -1;
	for(i = 0; i < 128; i++)
		buf[i] = (uchar)(v[2 + i/4] >> ((i%4) * 8));
	return 0;
}
