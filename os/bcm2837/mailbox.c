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

/*
 * Post the buffer to a channel and wait for the reply.  Returns 0 on
 * success, -1 if the firmware rejected the request.
 */
static int
mboxcall(u32int chan, volatile u32int *buf)
{
	u32int v, want;

	want = (u32int)(BUSADDR(buf) & ~0xFUL) | (chan & 0xF);

	dsb();
	while(MBOX(Mboxstatus) & Mboxfull)
		;
	MBOX(Mboxwrite) = want;

	/*
	 * Replies for other channels can in principle turn up here, so
	 * keep reading until one for ours arrives.
	 */
	for(;;){
		while(MBOX(Mboxstatus) & Mboxempty)
			;
		v = MBOX(Mboxread);
		if((v & 0xF) == (chan & 0xF))
			break;
	}
	dsb();

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
