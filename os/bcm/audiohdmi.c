/*
 * Audio out of HDMI, on the BCM2835 family's HDMI block (a Zero 2 W, a
 * 3B+, a 3A+): #A on a Zero 2 W, which has no jack, and #A1 beside the
 * jack on the others (#1216; audio.h's Audioout, os/bcm2837/audioout.c).
 * Served by os/port/devaudio.c as audio(3), like the jack.
 *
 * HOW. The HDMI block has an audio FIFO, the MAI, which a DMA channel
 * feeds through the block's own DREQ, from the same ring of buffers the
 * jack uses (audioring.h). The MAI takes IEC 958 subframes, not
 * samples: one 32-bit word for each channel of each frame, the sample
 * in bits 12-27 (16 bits, high-aligned in the 24), the channel-status
 * bit for that frame in bit 30 and even parity in 31, and in bits 0-3 a
 * code for the preamble -- 8 for the first left of a 192-frame block, 2
 * for any other left, 4 for a right. That is alsa-lib's layout, which is
 * the one the block is programmed to read (the B-frame code 8 in
 * Audiopacket below).
 *
 * The sink makes its own audio clock from the TMDS clock and two numbers
 * sent with the audio, N and CTS: N = 128 fs / 1000 and CTS = the pixel
 * clock times N over 128 fs (HDMI 1.4 7.2). And the MAI takes samples
 * at the rate of a divider (MAI_SMP) on the HDMI state machine's clock,
 * HSM. The firmware set both clocks for the mode it chose; the pixel
 * clock is the firmware's to say (the mailbox's PIXEL clock) and HSM is
 * worked out here from the clock manager's registers, as Linux's
 * clk-bcm2835 does: its source and divider, then that source's PLL.
 *
 * THE FIRMWARE OWNS THE MODE. It chose the resolution and whether the
 * sink is driven as HDMI or as DVI, and DVI carries no sound: a sink so
 * driven is refused at open, with hdmi_drive=2 in config.txt as the
 * way to force HDMI. Nothing here touches the video.
 *
 * Each buffer is a whole number of 192-frame blocks, so a buffer always
 * begins a block, and a word's preamble and status bit depend only on
 * its place in the buffer: the writer and the interrupt's silence come
 * out alike without a count kept between them.
 *
 * Register offsets and fields are from the Raspberry Pi Linux vc4_hdmi
 * and clk-bcm2835 drivers (vc4_hdmi_regs.h, vc4_regs.h): hardware facts,
 * written here in this tree's way.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"
#include "../port/error.h"
#include "../port/audio.h"
#include "audioring.h"

enum {
	HDREGS		= PHYSIO + 0x808000,	/* the HD block: the MAI */
	HDMIREGS	= PHYSIO + 0x902000,	/* the HDMI core */
	CMREGS		= PHYSIO + 0x101000,	/* the clock manager and the PLLs */
	MAIDATABUS	= 0x7E808000 + 0x20,	/* MAI_DATA as the DMA engine addresses it */

	/* HD block */
	Maictl		= 0x14,
		Mreset		= 1<<0,
		Merrorf		= 1<<1,
		Merrore		= 1<<2,
		Menable		= 1<<3,
		Mchnum		= 4,		/* the channel count's shift */
		Mflush		= 1<<9,
		Mempty		= 1<<10,
		Mfull		= 1<<11,
		Mwholsmp	= 1<<12,
		Mchalign	= 1<<13,
		Mdlate		= 1<<15,
	Maithr		= 0x18,
	Maifmt		= 0x1c,
		Fpcm		= 2<<16,
		Frate		= 8,		/* the sample-rate code's shift */
	Maismp		= 0x2c,

	/* HDMI core */
	Maichanmap	= 0x090,
	Maiconfig	= 0x094,
		Cbitrev		= 1<<26,
		Cfmtrev		= 1<<27,
	Audiopacket	= 0x09c,
		Pzeroinactive	= 1<<24,
		Pzeroflat	= 1<<29,
		Pbframe		= 10,		/* the B-frame code's shift */
	Ramcfg		= 0x0a0,
		Ramenable	= 1<<16,
	Ramstatus	= 0x0a4,
	Crpcfg		= 0x0a8,
		Extcts		= 1<<24,
		Crpdisable	= 1<<25,	/* no clock regeneration packets */
	Cts0		= 0x0ac,
	Cts1		= 0x0b0,
	Sched		= 0x0c0,
		Modehdmi	= 1<<0,
	Ramstart	= 0x400,
	Packetstride	= 0x24,
	Audioinfo	= 0x84,		/* the audio InfoFrame's type: packet 4 */

	/* clock manager */
	Cmhsmctl	= 0x088,
	Cmhsmdiv	= 0x08c,
	Xoschz		= 19200000,

	Dmachan		= 4,		/* the jack has 5 */
	Dreqhdmi	= 17,

	Csblock		= 192,		/* frames in an IEC 958 channel-status block */
	Maxframes	= 10*Csblock,	/* 43.5 ms at 44.1 kHz: the default, and what is allocated */
	Lowlat		= 2*Csblock,	/* at or below this the writer keeps ONE buffer ahead */
	Bufbytes	= Maxframes * 2 * 4,

	/* control block Ti */
	Tinten		= 1<<0,
	Tiwaitresp	= 1<<3,
	Tidestdreq	= 1<<6,
	Tisrcinc	= 1<<8,
	Tipermap	= 16,

	Pixelclock	= 9,		/* the mailbox's clock id */
	Settlems	= 300,		/* silence after a change of rate, for the sink to lock */
};

#define HD(r)	(*(volatile u32int*)((uintptr)HDREGS + (r)))
#define HDMI(r)	(*(volatile u32int*)((uintptr)HDMIREGS + (r)))
#define CM(r)	(*(volatile u32int*)((uintptr)CMREGS + (r)))

typedef struct Cb Cb;
struct Cb {
	u32int	ti;
	u32int	src;
	u32int	dst;
	u32int	len;
	u32int	stride;
	u32int	next;
	u32int	pad[2];
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	QLock	lk;		/* named: docs/PLAN9-C-UNDER-OTHER-COMPILERS.md */
	Lock	rlk;		/* the ring, between the writer and the interrupt */
	Rendez	r;
	int	running;	/* MAI and DMA are up */
	int	open;
	int	sounding;	/* written to since this open: a silenced buffer now is a gap */
	Cb	*cb;
	u32int	*buf[Nbuf];
	u32int	*quiet;		/* one block of silence, the words the interrupt copies */
	Ring	rg;
	int	woff;		/* words already in the writer's buffer */
	uchar	part[4];	/* a frame begun by a write that ended in it */
	int	npart;		/* its bytes */
	int	frames;		/* frames per buffer: a multiple of Csblock */
	ulong	played;
	ulong	underruns;
	uchar	cs[Csblock/8];	/* the channel status, a bit a frame */
	ulong	hsm;		/* the state machine's clock, Hz */
	ulong	pixel;		/* the pixel clock, Hz */
	int	n;
	ulong	cts;
	u32int	smp;		/* what MAI_SMP was given */
	ulong	settle;		/* ticks: no sound before this, after a new rate */
	Audio_t	av;
};

static Ctlr ctlr;

static Audio_t*
hdmidev(void)
{
	return &ctlr.av;
}

/*
 * A PLL's output and one of its channels, as clk-bcm2835 reads them:
 * the crystal times (NDIV + FRAC/2^20) over PDIV, doubled where the
 * feedback pre-divider is on (a bit of the PLL's second analogue
 * register), then the channel's divider, 0 meaning 256.
 */
static uvlong
pllhz(int ctrl, int frac, int ana0, u32int prediv, int chan)
{
	u32int c, ndiv, pdiv, fdiv, div;
	uvlong hz;

	c = CM(ctrl);
	ndiv = c & 0x3FF;
	pdiv = (c >> 12) & 7;
	fdiv = CM(frac) & 0xFFFFF;
	if(pdiv == 0)
		return 0;
	if(CM(ana0 + 4) & prediv){
		ndiv *= 2;
		fdiv *= 2;
	}
	hz = ((uvlong)Xoschz * (((uvlong)ndiv << 20) + fdiv) / pdiv) >> 20;
	div = CM(chan) & 0xFF;
	if(div == 0)
		div = 256;
	return hz / div;
}

/* HSM: its source, by the clock manager's number for it, over its divider (12.12) */
static ulong
hsmhz(void)
{
	u32int ctl, div;
	uvlong in;

	ctl = CM(Cmhsmctl);
	div = CM(Cmhsmdiv);
	switch(ctl & 0xF){
	case 1:
		in = Xoschz;
		break;
	case 4:
		in = pllhz(0x1100, 0x1200, 0x1010, 1<<14, 0x1500);	/* PLLA PER */
		break;
	case 5:
		in = pllhz(0x1120, 0x1220, 0x1030, 1<<14, 0x1520);	/* PLLC PER */
		break;
	case 6:
		in = pllhz(0x1140, 0x1240, 0x1050, 1<<14, 0x1540);	/* PLLD PER */
		break;
	case 7:
		in = pllhz(0x1160, 0x1260, 0x1070, 1<<11, 0x1360);	/* PLLH AUX */
		break;
	default:
		return 0;
	}
	if((div >> 12) == 0)
		return 0;
	return in * 4096 / div;
}

/* the pixel clock: the firmware's, or PLLH's PIX channel (a fixed tenth more) if it will not say */
static ulong
pixelhz(void)
{
	ulong hz;

	hz = mboxclockrate(Pixelclock);
	if(hz == 0)
		hz = pllhz(0x1160, 0x1260, 0x1070, 1<<11, 0x1560) / 10;
	return hz;
}

/* MAI_FMT's code for a rate, and IEC 958's (channel status byte 3) */
static int
ratecode(int rate, int *iec)
{
	switch(rate){
	case 32000:
		*iec = 0x03;
		return 7;
	case 44100:
		*iec = 0x00;
		return 8;
	case 48000:
		*iec = 0x02;
		return 9;
	}
	return -1;
}

/*
 * MAI_SMP: N/M as near as fits to HSM/fs, N in 24 bits and M at most
 * 256 (M-1 in the field), which is what makes the MAI take fs samples a
 * second.
 */
static u32int
maismp(ulong hsm, int rate)
{
	uvlong n, bn, bm, m, err, best;

	best = ~0ULL;
	bn = bm = 1;
	for(m = 1; m <= 256; m++){
		n = ((uvlong)hsm * m + rate/2) / rate;
		if(n == 0 || n > 0xFFFFFF)
			break;
		err = n * rate > (uvlong)hsm * m? n * rate - (uvlong)hsm * m : (uvlong)hsm * m - n * rate;
		err = err * 256 / m;	/* the error per sample, scaled alike for each m */
		if(err < best){
			best = err;
			bn = n;
			bm = m;
			if(err == 0)
				break;
		}
	}
	return (u32int)(bn << 8) | (u32int)(bm - 1);
}

/* odd number of ones */
static int
parity(u32int w)
{
	w ^= w >> 16;
	w ^= w >> 8;
	w ^= w >> 4;
	w ^= w >> 2;
	w ^= w >> 1;
	return w & 1;
}

/* the subframe for sample s (signed 16-bit), left or right, at frame f of its block */
static u32int
subframe(int s, int right, int f)
{
	u32int w;

	w = ((u32int)s & 0xFFFF) << 12;
	if((ctlr.cs[f >> 3] >> (f & 7)) & 1)
		w |= 1<<30;
	if(parity(w))
		w |= 1<<31;
	if(right)
		w |= 0x4;
	else if(f == 0)
		w |= 0x8;
	else
		w |= 0x2;
	return w;
}

/*
 * The channel status, the same for both channels (IEC 60958-3, the
 * consumer format): PCM, no copyright asserted, an original from a PCM
 * coder, the rate, 16-bit words.
 */
static void
setstatus(int iecrate)
{
	int i;

	memset(ctlr.cs, 0, sizeof ctlr.cs);
	ctlr.cs[0] = 0x04;
	ctlr.cs[1] = 0x82;
	ctlr.cs[3] = iecrate;
	ctlr.cs[4] = 0x02;
	for(i = 0; i < Csblock; i++){
		ctlr.quiet[2*i] = subframe(0, 0, i);
		ctlr.quiet[2*i+1] = subframe(0, 1, i);
	}
}

static void
fillsilence(u32int *b)
{
	int i;

	for(i = 0; i < ctlr.frames; i += Csblock)
		memmove(b + 2*i, ctlr.quiet, Csblock * 2 * sizeof(u32int));
	cachedwbse(b, ctlr.frames * 2 * 4);
}

/*
 * The audio InfoFrame (CEA-861 6.6): two channels, and everything else
 * left to the stream. In the packet RAM as the block reads it: seven
 * bytes to two words, the first of three bytes; the rest of the
 * packet's room zero, or a sink's checksum sees it. Stopped while it is
 * written, and started again.
 */
static void
infoframe(void)
{
	uchar f[14];
	int i, sum, reg, end;

	memset(f, 0, sizeof f);
	f[0] = Audioinfo;
	f[1] = 1;
	f[2] = 10;
	f[4] = 1;		/* CC: two channels; CT 0: refer to the stream */
	sum = 0;
	for(i = 0; i < (int)nelem(f); i++)
		sum += f[i];
	f[3] = -sum;

	if((HDMI(Ramcfg) & Ramenable) == 0)
		HDMI(Ramcfg) |= Ramenable;
	HDMI(Ramcfg) &= ~(1 << (Audioinfo - 0x80));
	for(i = 0; i < 100 && (HDMI(Ramstatus) & (1 << (Audioinfo - 0x80))); i++)
		microdelay(1000);
	reg = Ramstart + Packetstride * (Audioinfo - 0x80);
	end = reg + Packetstride;
	for(i = 0; i < (int)nelem(f); i += 7){
		HDMI(reg) = f[i] | f[i+1]<<8 | f[i+2]<<16;
		reg += 4;
		HDMI(reg) = f[i+3] | f[i+4]<<8 | f[i+5]<<16 | f[i+6]<<24;
		reg += 4;
	}
	for(; reg < end; reg += 4)
		HDMI(reg) = 0;
	HDMI(Ramcfg) |= 1 << (Audioinfo - 0x80);
}

/*
 * The MAI set for a rate: reset, its sample divider, two channels whole
 * and aligned, PCM at that rate; the channel map and the packet layout;
 * N and CTS; the InfoFrame. As vc4_hdmi's startup and prepare do it.
 */
static void
prepare(Ctlr *c, int rate)
{
	int code, iec;
	uvlong cts;

	code = ratecode(rate, &iec);
	if(code < 0)
		error("audio: HDMI plays at 32000, 44100 or 48000 Hz");
	HD(Maictl) = Mreset | Mflush | Mdlate | Merrore | Merrorf;
	c->smp = maismp(c->hsm, rate);
	HD(Maismp) = c->smp;
	HD(Maictl) = (2 << Mchnum) | Mwholsmp | Mchalign | Menable;
	HD(Maifmt) = (code << Frate) | Fpcm;
	HD(Maithr) = 8<<24 | 8<<16 | 6<<8 | 8;		/* panic high and low, DREQ high and low */
	HDMI(Maiconfig) = Cbitrev | Cfmtrev | 3;	/* channels 0 and 1 */
	HDMI(Maichanmap) = 0 | 1<<3;			/* each to itself */
	HDMI(Audiopacket) = Pzeroflat | Pzeroinactive | (8 << Pbframe) | 3;
	c->n = 128 * rate / 1000;
	cts = (uvlong)c->pixel * c->n / (128 * (uvlong)rate);
	c->cts = cts;
	/*
	 * The pair changes together: the sink is not sent the new N with
	 * the old CTS, a clock it would chase, while they are written.
	 */
	HDMI(Crpcfg) = Crpdisable | Extcts | c->n;
	HDMI(Cts0) = c->cts;
	HDMI(Cts1) = c->cts;
	HDMI(Crpcfg) = Extcts | c->n;
	infoframe();
	setstatus(iec);
}

/* the end of a buffer: audiopwm.c's, with this file's silence */
static void
audiointr(void *a)
{
	Ctlr *c;
	int done;

	c = a;
	c->played++;
	ilock(&c->rlk);
	switch(ringplayed(&c->rg)){
	case Rplay:
		break;
	case Rmove:
		memmove(c->buf[(c->rg.pbuf + 1) % Nbuf], c->buf[c->rg.pbuf], c->woff * sizeof(u32int));
		ringmove(&c->rg);
		/* fall through */
	case Rsilence:
		fillsilence(c->buf[c->rg.pbuf]);
		if(c->open && c->sounding)
			c->underruns++;
		break;
	}
	/*
	 * And the buffer just played, silenced now, while the engine is
	 * three buffers from it. Silenced only when it is reached, as
	 * above, it was being read as it was cleared: the first of it
	 * played what it held from last time round, and a tone stopped
	 * by a close (tone(1) closes as its sine ends) was followed by
	 * three clicks, one a buffer, on an HDMI TV. A writer still in it
	 * (it filled a buffer as the engine played it) keeps it.
	 */
	done = (c->rg.pbuf + Nbuf - 1) % Nbuf;
	if(done != c->rg.writing && !c->rg.full[done])
		fillsilence(c->buf[done]);
	iunlock(&c->rlk);
	wakeup(&c->r);
}

static void
ring(Ctlr *c)
{
	int i;

	for(i = 0; i < Nbuf; i++){
		fillsilence(c->buf[i]);
		c->cb[i].ti = Tinten | Tiwaitresp | Tidestdreq | Tisrcinc | (Dreqhdmi << Tipermap);
		c->cb[i].src = BUSADDR(PADDR(c->buf[i]));
		c->cb[i].dst = MAIDATABUS;
		c->cb[i].len = c->frames * 2 * 4;
		c->cb[i].stride = 0;
		c->cb[i].next = BUSADDR(PADDR(&c->cb[(i+1) % Nbuf]));
	}
	cachedwbse(c->cb, Nbuf * sizeof(Cb));
	ringreset(&c->rg);
	c->woff = 0;
}

/* "buf n": the buffer as a share of Maxframes, in whole blocks, one at least */
static int
framesfor(ulong pct)
{
	int f;

	f = Maxframes * pct / 100 / Csblock * Csblock;
	if(f < Csblock)
		f = Csblock;
	if(f > Maxframes)
		f = Maxframes;
	return f;
}

static void
setframes(Ctlr *c, int frames)
{
	int i;

	if(frames == c->frames)
		return;
	for(i = 0; i < Nbuf; i++)
		if(c->rg.full[i] || c->woff != 0)
			error("audio: sound is queued; set buf before writing");
	if(c->running)
		dmastop(Dmachan);
	c->frames = frames;
	c->rg.ahead = frames <= Lowlat ? 1 : Nbuf - 1;
	if(c->running){
		ring(c);
		dmastart(Dmachan, c->cb);
	}
}

/*
 * Up: refused, with the reason, where the firmware drove the sink as
 * DVI or the clocks cannot be read. It stays up after the last close,
 * playing silence, as the jack does: a sink that loses its audio stream
 * mutes, and some take seconds to unmute for the next sound.
 */
static void
start(Ctlr *c)
{
	int i;

	if(c->running)
		return;
	if((HDMI(Sched) & Modehdmi) == 0)
		error("audio: the firmware drove the HDMI sink as DVI, which has no sound (hdmi_drive=2 in config.txt)");
	c->hsm = hsmhz();
	if(c->hsm == 0)
		error("audio: the HDMI state machine's clock cannot be read");
	c->pixel = pixelhz();
	if(c->pixel == 0)
		error("audio: the firmware gives no pixel clock");
	if(c->cb == nil){
		c->cb = dmaalloc(Nbuf * sizeof(Cb), 32);
		for(i = 0; i < Nbuf; i++)
			c->buf[i] = dmaalloc(Bufbytes, 32);
		c->quiet = malloc(Csblock * 2 * sizeof(u32int));
		if(c->cb == nil || c->buf[0] == nil || c->buf[Nbuf-1] == nil || c->quiet == nil)
			error(Enomem);
	}
	prepare(c, c->av.out.rate);
	ring(c);
	if(dmaenable(Dmachan, audiointr, c, "audio hdmi") < 0)
		error("audio: no DMA channel");
	dmastart(Dmachan, c->cb);
	c->running = 1;
}

static void
hdmiinit(void)
{
	audio_info_init(&ctlr.av);
	ctlr.frames = Maxframes;
	ctlr.rg.ahead = Nbuf - 1;
	ctlr.av.out.buf = 100;
	ctlr.av.out.rate = 44100;
	ctlr.av.out.chan = 2;
	ctlr.av.out.bits = 16;
}

static void
hdmiopen(Chan *c, int omode)
{
	USED(c);
	if(omode == OREAD || omode == ORDWR)
		error("audio: HDMI has no input");
	qlock(&ctlr.lk);
	if(waserror()){
		qunlock(&ctlr.lk);
		nexterror();
	}
	if(ctlr.open)
		error(Einuse);
	start(&ctlr);
	ctlr.sounding = 0;
	ctlr.npart = 0;
	ctlr.open = 1;
	poperror();
	qunlock(&ctlr.lk);
}

static void
hdmiclose(Chan *c)
{
	USED(c);
	qlock(&ctlr.lk);
	ctlr.open = 0;
	ctlr.sounding = 0;
	ctlr.npart = 0;		/* half a frame at the end is not played */
	/* the last buffer, part written: the rest silence, and played */
	if(ctlr.woff != 0){
		u32int *b;
		int f;

		b = ctlr.buf[ctlr.rg.wbuf];
		for(; ctlr.woff < ctlr.frames * 2; ctlr.woff += 2){
			f = (ctlr.woff / 2) % Csblock;
			b[ctlr.woff] = ctlr.quiet[2*f];
			b[ctlr.woff+1] = ctlr.quiet[2*f+1];
		}
		cachedwbse(b, ctlr.frames * 2 * 4);
		ilock(&ctlr.rlk);
		ringfilled(&ctlr.rg);
		iunlock(&ctlr.rlk);
		ctlr.woff = 0;
	}
	if(ctlr.frames != Maxframes && !waserror()){
		ctlr.woff = 0;
		memset(ctlr.rg.full, 0, sizeof ctlr.rg.full);
		ctlr.rg.writing = -1;
		ctlr.rg.parked = 0;
		setframes(&ctlr, Maxframes);
		ctlr.av.out.buf = 100;
		poperror();
	}
	qunlock(&ctlr.lk);
}

static long
hdmiread(Chan *c, void *va, long count, vlong offset)
{
	USED(c); USED(va); USED(count); USED(offset);
	error("audio: HDMI has no input");
	return 0;
}

static int
roomfor(void *a)
{
	return ringroom(&((Ctlr*)a)->rg);
}

/* a sample at a channel's gain (0 to Audio_Max_Val) */
static int
gain(int s, int g)
{
	return (long)s * g / Audio_Max_Val;
}

static long
hdmiwrite(Chan *c, void *va, long count, vlong offset)
{
	uchar *p;
	long n, ba;
	int l, r, bits, chans, lg, rg, f;
	u32int *b;

	USED(c); USED(offset);
	/* a new rate: the sink is still locking to it (hdmictl) */
	while((long)(ctlr.settle - MACHP(0)->ticks) > 0)
		tsleep(&up->sleep, return0, 0, TK2MS(ctlr.settle - MACHP(0)->ticks) + 1);
	qlock(&ctlr.lk);
	if(waserror()){
		ilock(&ctlr.rlk);
		ringpark(&ctlr.rg);
		iunlock(&ctlr.rlk);
		qunlock(&ctlr.lk);
		nexterror();
	}
	if(!ctlr.open)
		error(Eperm);
	bits = ctlr.av.out.bits;
	chans = ctlr.av.out.chan;
	lg = ctlr.av.out.left;
	rg = ctlr.av.out.right;
	ba = bits * chans / Bits_Per_Byte;
	p = va;
	ilock(&ctlr.rlk);
	ringunpark(&ctlr.rg);
	iunlock(&ctlr.rlk);
	/*
	 * A write need not be whole frames. It was refused if it was
	 * not, and sound from a network connection -- cat from a TCP
	 * stream, whose reads are what arrived -- stopped at the first
	 * write with a frame cut in two. The part of a frame a write
	 * ends with is kept, and the next write finishes it.
	 */
	for(n = 0; n < count; n++){
		ctlr.part[ctlr.npart++] = p[n];
		if(ctlr.npart < ba)
			continue;
		ctlr.npart = 0;
		if(ctlr.woff == 0){
			ringbegin(&ctlr.rg);
			while(!roomfor(&ctlr))
				sleep(&ctlr.r, roomfor, &ctlr);
			ilock(&ctlr.rlk);
			ringwriting(&ctlr.rg);
			iunlock(&ctlr.rlk);
		}
		if(bits == 16){
			l = (short)(ctlr.part[0] | (ctlr.part[1] << 8));
			r = chans == 2? (short)(ctlr.part[2] | (ctlr.part[3] << 8)) : l;
		}else{
			l = ((int)ctlr.part[0] - 128) << 8;
			r = chans == 2? ((int)ctlr.part[1] - 128) << 8 : l;
		}
		b = ctlr.buf[ctlr.rg.wbuf];
		f = (ctlr.woff / 2) % Csblock;
		b[ctlr.woff++] = subframe(gain(l, lg), 0, f);
		b[ctlr.woff++] = subframe(gain(r, rg), 1, f);
		if(ctlr.woff >= ctlr.frames * 2){
			cachedwbse(b, ctlr.frames * 2 * 4);
			ilock(&ctlr.rlk);
			ringfilled(&ctlr.rg);
			iunlock(&ctlr.rlk);
			ctlr.woff = 0;
			ctlr.sounding = 1;
		}
	}
	ilock(&ctlr.rlk);
	ringpark(&ctlr.rg);
	iunlock(&ctlr.rlk);
	poperror();
	qunlock(&ctlr.lk);
	return count;
}

static long
hdmictl(Chan *c, void *va, long count, vlong offset)
{
	Audio_t tmp;
	int iec;

	USED(c); USED(offset);
	tmp = ctlr.av;
	tmp.in.flags = 0;
	tmp.out.flags = 0;
	if(!audioparse(va, count, &tmp))
		error(Ebadarg);
	/*
	 * A verb with no "in" or "out" sets both (audioparse), and was
	 * refused here for the input it named: "rate 48000 chans 2 bits
	 * 16", as tone(1) writes it, changed nothing, and the tone played
	 * at the old rate. Only a line that sets input alone is refused;
	 * the input half of one that sets both is dropped.
	 */
	if(tmp.in.flags != 0 && tmp.out.flags == 0)
		error("audio: HDMI has no input");
	tmp.in = ctlr.av.in;
	qlock(&ctlr.lk);
	if(waserror()){
		qunlock(&ctlr.lk);
		nexterror();
	}
	if(tmp.out.flags & AUDIO_ENC_FLAG && tmp.out.enc != Audio_Pcm_Val)
		error("audio: PCM only");
	if(tmp.out.flags & AUDIO_BITS_FLAG && tmp.out.bits != 8 && tmp.out.bits != 16)
		error("audio: 8 or 16 bits");
	if(tmp.out.flags & AUDIO_CHAN_FLAG && tmp.out.chan != 1 && tmp.out.chan != 2)
		error("audio: 1 or 2 channels");
	if(tmp.out.flags & AUDIO_RATE_FLAG && ratecode(tmp.out.rate, &iec) < 0)
		error("audio: HDMI plays at 32000, 44100 or 48000 Hz");
	if(tmp.out.flags & AUDIO_RATE_FLAG && tmp.out.rate != ctlr.av.out.rate && ctlr.running){
		dmastop(Dmachan);
		prepare(&ctlr, tmp.out.rate);
		/*
		 * A new rate is a new stream to the sink, which mutes while it
		 * locks to it: sound written at once was played into that, and
		 * a tone after a change from 44.1 to 48 kHz began and ended
		 * garbled on an HDMI TV where the same tone at an unchanged
		 * rate was clean. Silence for a moment first (hdmiwrite).
		 */
		ctlr.settle = MACHP(0)->ticks + Settlems * HZ / 1000;
		ring(&ctlr);
		dmastart(Dmachan, ctlr.cb);
	}
	if(tmp.out.flags & AUDIO_BUF_FLAG)
		setframes(&ctlr, framesfor(tmp.out.buf));
	if(tmp.out.bits != ctlr.av.out.bits || tmp.out.chan != ctlr.av.out.chan)
		ctlr.npart = 0;		/* a frame begun in the old size is not one in the new */
	tmp.out.flags = 0;
	ctlr.av = tmp;
	poperror();
	qunlock(&ctlr.lk);
	return count;
}

/*
 * #A1/audiostat (#A on a Zero 2 W): the jack's line, then what HDMI
 * adds -- the mode the firmware drove the sink in, the two clocks this
 * file read and the N and CTS it sent from them, MAI_SMP, and the MAI's
 * own state (its control register: bit 10 empty, 11 full, 1 and 2 its
 * error flags).
 */
static char*
hdmistatus(char *buf, char *e)
{
	char *mode;
	u32int mai;

	/*
	 * The registers only once the engine is up, which open checked
	 * could be: under QEMU, which models no HDMI block, a read of
	 * one may fault, and reading audiostat must not.
	 */
	mode = "-";
	mai = 0;
	if(ctlr.running){
		mode = (HDMI(Sched) & Modehdmi)? "hdmi" : "dvi";
		mai = HD(Maictl);
	}
	return seprint(buf, e, "engine %s open %d mode %s rate %lud chans %lud bits %lud frames %d ahead %d played %lud underruns %lud hsm %lud pixel %lud n %d cts %lud smp %#ux mai %#ux\n",
		ctlr.running? "running" : "idle", ctlr.open, mode,
		ctlr.av.out.rate, ctlr.av.out.chan, ctlr.av.out.bits,
		ctlr.frames, ctlr.rg.ahead, ctlr.played, ctlr.underruns,
		ctlr.hsm, ctlr.pixel, ctlr.n, ctlr.cts, ctlr.smp, mai);
}

Audioout audiohdmiout = {
	.name	= "hdmi",
	.init	= hdmiinit,
	.open	= hdmiopen,
	.read	= hdmiread,
	.write	= hdmiwrite,
	.ctl	= hdmictl,
	.close	= hdmiclose,
	.status	= hdmistatus,
	.dev	= hdmidev,
};
