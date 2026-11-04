/*
 * Audio on the Pi 3B+'s 3.5 mm jack: the SoC's two PWM channels through
 * the board's RC filters, fed by DMA. Served as /dev/audio and
 * /dev/audioctl by os/port/devaudio.c exactly as the hosted emulator
 * serves them (audio(3)), so a program that plays on the emulator plays
 * here; this file is the platform half that file expects
 * (audio_file_open, audio_file_write, audio_ctl_write, ...).
 *
 * HOW THE SOUND IS MADE. A PWM channel in FIFO mode turns each word it
 * is given into one pulse whose width is that word out of a range;
 * pulses at ~44 kHz through the filter are a voltage, and a stream of
 * them is the waveform. With the range near 2048 the resolution is 11
 * bits, which through this filter is what the jack is good for; a
 * 16-bit sample comes down to it with its error carried forward (level).
 * The PWM clock comes from the
 * clock manager: PLLD (AUDIOPLLDHZ: 500 MHz on a 3B+, 750 on a 4B), by
 * a whole number, and the range is what makes clock / range the sample
 * rate (audiolevel.h). Both channels
 * share one FIFO and take words alternately (left, right), so a stereo
 * frame is two words in order.
 *
 * WHY DMA AND NOT A PROCESS. The FIFO holds sixteen words; at 44.1 kHz
 * stereo that is 180 microseconds, and nothing on the kernel side
 * wakes that reliably. So a DMA channel (dma.c) feeds the FIFO, paced
 * by the PWM's DREQ, from a ring of two buffers whose control blocks
 * point at each other: the engine plays forever, and at the end of each
 * buffer it interrupts. The interrupt marks that buffer free; a writer
 * blocked for room is woken; and a buffer the writer has NOT refilled
 * by the time it comes round again is silenced first -- a gap is a
 * gap, not the last half second played twice.
 *
 * SILENCE IS A LEVEL, NOT NOTHING. The idle jack on this board buzzes
 * (#636): an unconfigured PWM pin floats. Once this device has been
 * opened the PWM runs continuously at the range's midpoint whether or
 * not anyone is writing, which is a steady DC level after the filter
 * and therefore quiet. It keeps running after close for that reason.
 *
 * WHAT IS NOT HERE. Input (the jack has none), HDMI audio (a different
 * path through the VideoCore), and any format but PCM 8/16-bit, 1 or 2
 * channels, at the rates audio(3) lists; a write in another format is
 * refused with Ebadarg by the generic layer's tables.
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

#define Audio_Mic_Val		0
#define Audio_Linein_Val	1
#define Audio_Speaker_Val	2
#define Audio_Headphone_Val	3
#define Audio_Lineout_Val	4
#define Audio_Pcm_Val		0
#define Audio_Ulaw_Val		1
#define Audio_Alaw_Val		2
#include "../port/audio-tbls.h"
#include "audioring.h"
#include "audiolevel.h"

enum {
	PWMREGS		= PHYSIO + AUDIOPWMOFF,	/* the board's: io.h says which block the jack's pins carry */
	CMREGS		= PHYSIO + 0x101000,
	PWMFIFOBUS	= 0x7E000000 + AUDIOPWMOFF + 0x18,	/* the FIFO as the DMA engine addresses it */

	/* PWM registers */
	Pctl		= 0x00,
	Psta		= 0x04,
	Pdmac		= 0x08,
	Prng1		= 0x10,
	Pdat1		= 0x14,
	Pfif1		= 0x18,
	Prng2		= 0x20,
	Pdat2		= 0x24,

	/* Pctl */
	Pwen1		= 1<<0,
	Usef1		= 1<<5,
	Clrf1		= 1<<6,
	Pwen2		= 1<<8,
	Usef2		= 1<<13,

	/* Psta */
	Pberr		= 1<<8,
	Pgapo1		= 1<<4,
	Pgapo2		= 1<<5,

	/* Pdmac */
	Denab		= 1<<31,
	Dpanic		= 7<<8,
	Ddreq		= 7<<0,

	/* clock manager */
	Cmpwmctl	= 0xA0,
	Cmpwmdiv	= 0xA4,
	Cmpasswd	= 0x5A000000,
	Cmbusy		= 1<<7,
	Cmenab		= 1<<4,
	Cmkill		= 1<<5,
	Cmsrcplld	= 6,
	Plldhz		= AUDIOPLLDHZ,


	Gpiopwm0	= 40,		/* PWM0 on the jack's left */
	Gpiopwm1	= 41,		/* PWM1, right */

	Dmachan		= 5,		/* of the ARM's 0-6; SD and USB use none here */
	Dreqpwm		= AUDIODREQ,	/* the PWM's DREQ line (io.h) */

	Maxframes	= 2048,		/* stereo frames per buffer: 46 ms at 44.1 kHz; the default, and what is allocated */
	Minframes	= 64,		/* 1.5 ms */
	Lowlat		= 256,		/* at or below this the writer keeps ONE buffer ahead, not three */
	Bufbytes	= Maxframes * 2 * 4,

	/* control block Ti */
	Tinten		= 1<<0,
	Tiwaitresp	= 1<<3,
	Tidestdreq	= 1<<6,
	Tisrcinc	= 1<<8,
	Tipermap	= 16,
};

#define PWM(r)	(*(volatile u32int*)((uintptr)PWMREGS + (r)))
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
	QLock	lk;		/* a NAMED member: "QLock;" declares nothing under clang (docs/PLAN9-C-UNDER-OTHER-COMPILERS.md) */
	Rendez	r;
	int	running;	/* clock, PWM and DMA are up */
	int	open;
	Cb	*cb;		/* Nbuf control blocks, 32-byte aligned */
	u32int	*buf[Nbuf];	/* the ring */
	Ring	rg;		/* the engine's place, the writer's, what waits: audioring.h */
	int	woff;		/* words already in the writer's buffer */
	int	frames;		/* stereo frames per buffer now: Maxframes unless audioctl's buf said less (#653) */
	ulong	played;		/* buffers played out, for the curious */
	ulong	underruns;	/* buffers silenced for want of data */
	int	carry[2];	/* each channel's rounding error: level */
	int	range;		/* pulse range: pwmclock */
	int	silence;	/* its middle */
	Audio_t	av;
};

static Ctlr ctlr;

Audio_t*
getaudiodev(void)
{
	return &ctlr.av;
}

static void
pwmclock(int rate)
{
	u32int divi, divf;

	divi = audiodivider(Plldhz, rate);
	divf = 0;
	ctlr.range = audiorange(Plldhz, rate);
	ctlr.silence = ctlr.range / 2;
	CM(Cmpwmctl) = Cmpasswd | Cmkill;
	while(CM(Cmpwmctl) & Cmbusy)
		;
	CM(Cmpwmdiv) = Cmpasswd | (divi << 12) | divf;
	CM(Cmpwmctl) = Cmpasswd | Cmsrcplld;
	microdelay(10);
	CM(Cmpwmctl) = Cmpasswd | Cmsrcplld | Cmenab;
	while((CM(Cmpwmctl) & Cmbusy) == 0)
		;
}

/*
 * LATENCY (#653). A sound written now is heard when the engine reaches
 * the buffer it went into. With 2048-frame buffers and the writer three
 * ahead that is 50 to 150 ms: right for playing a file, since big
 * buffers ride out scheduling gaps, and useless for anything that
 * answers a person -- a click, a beep, a sidetone, speech -- where past
 * 20 ms a sound stops feeling caused by the action. audio(3) already
 * has the control for it: "buf n", the buffer size as a percentage,
 * which this driver used to ignore. 100 is the default; the frames are
 * the power of two at or below that share of 2048, and at least 64:
 *
 *	buf	100	50	25	13	7	4
 *	frames	2048	1024	512	256	128	64
 *	ms	46	23	12	5.8	2.9	1.5	(at 44.1 kHz)
 *
 * At 256 frames and below the writer is held to ONE buffer ahead of
 * the engine, so the worst case is two buffers: about 6 ms at buf 7.
 * The cost is an interrupt per buffer and a writer that must keep up;
 * one that does not is silenced for the gap, as ever, and the underrun
 * count in the status line says how often. The setting lasts for one
 * open: close puts the default back.
 */
static int
framesfor(ulong pct)
{
	int want, f;

	want = Maxframes * pct / 100;
	for(f = Minframes; f * 2 <= want && f * 2 <= Maxframes; f *= 2)
		;
	return f;
}

static void
fillsilence(u32int *b)
{
	int i, words;

	words = ctlr.frames * 2;
	for(i = 0; i < words; i++)
		b[i] = ctlr.silence;
	cachedwbse(b, words * 4);
}

/*
 * The end of a buffer: it is free, and the engine has moved on to the
 * next, which plays silence if nobody wrote it in time. Which buffer
 * finished is COUNTED from the one the chain was started on, not read
 * back from the engine's control-block register: the first cut read
 * CONBLK_AD, which at interrupt time is the finished block as often as
 * the next, and the writer was freed the wrong buffer half the time --
 * one underrun in two while a program that could fill ten buffers a
 * second waited on the wrong one.
 */
static void
audiointr(void *a)
{
	Ctlr *c;

	c = a;
	c->played++;
	if(ringplayed(&c->rg)){
		fillsilence(c->buf[c->rg.pbuf]);
		c->underruns++;
	}
	wakeup(&c->r);
}

/* the ring of control blocks, for the buffer length in force, all silent */
static void
ring(Ctlr *c)
{
	int i;

	for(i = 0; i < Nbuf; i++){
		fillsilence(c->buf[i]);
		c->cb[i].ti = Tinten | Tiwaitresp | Tidestdreq | Tisrcinc | (Dreqpwm << Tipermap);
		c->cb[i].src = BUSADDR(PADDR(c->buf[i]));
		c->cb[i].dst = PWMFIFOBUS;
		c->cb[i].len = c->frames * 2 * 4;
		c->cb[i].stride = 0;
		c->cb[i].next = BUSADDR(PADDR(&c->cb[(i+1) % Nbuf]));
	}
	cachedwbse(c->cb, Nbuf * sizeof(Cb));
	ringreset(&c->rg);
	c->woff = 0;
}

/*
 * A new buffer length. The engine reads the control blocks as it goes,
 * so they are not changed under it: it is stopped, the ring rebuilt,
 * and started again, a few milliseconds of silence. Refused while
 * anything written is still waiting to be played, which a program
 * avoids by setting buf before it writes.
 */
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

static void
start(Ctlr *c)
{
	int i;

	if(c->running)
		return;
	if(c->cb == nil){
		c->cb = dmaalloc(Nbuf * sizeof(Cb), 32);	/* the DMA engine reads these: dmamem.c */
		for(i = 0; i < Nbuf; i++)
			c->buf[i] = dmaalloc(Bufbytes, 32);
		if(c->cb == nil || c->buf[0] == nil || c->buf[Nbuf-1] == nil)
			error(Enomem);
	}
	c->range = audiorange(Plldhz, c->av.out.rate);
	c->silence = c->range / 2;	/* what ring() fills with */
	ring(c);

	gpioclaim(Gpiopwm0, "audio");
	gpioclaim(Gpiopwm1, "audio");
	gpiofunc(Gpiopwm0, Gpioalt0);
	gpiofunc(Gpiopwm1, Gpioalt0);

	PWM(Pctl) = 0;
	microdelay(10);
	pwmclock(c->av.out.rate);
	PWM(Prng1) = ctlr.range;
	PWM(Prng2) = ctlr.range;
	PWM(Pdmac) = Denab | Dpanic | Ddreq;
	PWM(Pctl) = Clrf1;
	microdelay(10);
	/* FIFO mode on both channels; MSEN clear: the PWM algorithm spreads the pulses */
	PWM(Pctl) = Pwen1 | Usef1 | Pwen2 | Usef2;

	if(dmaenable(Dmachan, audiointr, c, "audio") < 0)
		error("audio: no DMA channel");
	dmastart(Dmachan, c->cb);
	c->running = 1;
}

void
audio_file_init(void)
{
	audio_info_init(&ctlr.av);
	ctlr.frames = Maxframes;
	ctlr.rg.ahead = Nbuf - 1;
	ctlr.av.out.buf = 100;
	ctlr.av.out.rate = 44100;
	ctlr.av.out.chan = 2;
	ctlr.av.out.bits = 16;
}

void
audio_file_open(Chan *c, int omode)
{
	USED(c);
	if(omode == OREAD || omode == ORDWR)
		error("audio: the jack has no input");
	qlock(&ctlr.lk);
	if(waserror()){
		qunlock(&ctlr.lk);
		nexterror();
	}
	if(ctlr.open)
		error(Einuse);
	start(&ctlr);
	ctlr.open = 1;
	poperror();
	qunlock(&ctlr.lk);
}

void
audio_file_close(Chan *c)
{
	USED(c);
	qlock(&ctlr.lk);
	ctlr.open = 0;
	/*
	 * The last buffer, part written: the rest is silence, and it goes
	 * to be played. It used to stay as it was -- the end of the sound
	 * never heard, and the next program to open carrying on in it.
	 */
	if(ctlr.woff != 0){
		u32int *b;

		b = ctlr.buf[ctlr.rg.wbuf];
		while(ctlr.woff < ctlr.frames * 2)
			b[ctlr.woff++] = ctlr.silence;
		cachedwbse(b, ctlr.frames * 2 * 4);
		ringfilled(&ctlr.rg);
		ctlr.woff = 0;
	}
	/* the PWM keeps running at silence: see the comment at the top */
	if(ctlr.frames != Maxframes && !waserror()){
		/* a low-latency setting is one program's, for one open */
		ctlr.woff = 0;
		memset(ctlr.rg.full, 0, sizeof ctlr.rg.full);
		ctlr.rg.writing = -1;
		setframes(&ctlr, Maxframes);
		ctlr.av.out.buf = 100;
		poperror();
	}
	qunlock(&ctlr.lk);
}

long
audio_file_read(Chan *c, void *va, long count, vlong offset)
{
	USED(c); USED(va); USED(count); USED(offset);
	error("audio: the jack has no input");
	return 0;
}

/*
 * May the writer start on its next buffer? Not while it is still to be
 * played from last time round; and in the low-latency case not while it
 * is more than one in front of the engine, which is the whole of how
 * the latency is kept down.
 */
static int
roomfor(void *a)
{
	return ringroom(&((Ctlr*)a)->rg);
}

/*
 * One sample to a PWM word: signed 16-bit (or unsigned 8-bit) to
 * 0..range-1 around its middle, scaled by the channel's gain.
 */
static u32int
level(int s, int gain, int *carry)
{
	return audiolevel(s, gain, Audio_Max_Val, ctlr.range, carry);
}

long
audio_file_write(Chan *c, void *va, long count, vlong offset)
{
	uchar *p;
	long n, ba;
	int l, r, bits, chans, lg, rg;
	u32int *b;

	USED(c); USED(offset);
	qlock(&ctlr.lk);
	if(waserror()){
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
	if(count % ba)
		error(Ebadarg);
	p = va;
	for(n = 0; n < count; n += ba){
		if(ctlr.woff == 0){
			ringbegin(&ctlr.rg);	/* where it starts: audioring.h */
			/* a fresh buffer: wait for the engine to be done with it */
			while(!roomfor(&ctlr))
				sleep(&ctlr.r, roomfor, &ctlr);
			ringwriting(&ctlr.rg);
		}
		if(bits == 16){
			l = (short)(p[n] | (p[n+1] << 8));
			r = chans == 2? (short)(p[n+2] | (p[n+3] << 8)) : l;
		}else{
			l = ((int)p[n] - 128) << 8;
			r = chans == 2? ((int)p[n+1] - 128) << 8 : l;
		}
		b = ctlr.buf[ctlr.rg.wbuf];
		b[ctlr.woff++] = level(l, lg, &ctlr.carry[0]);
		b[ctlr.woff++] = level(r, rg, &ctlr.carry[1]);
		if(ctlr.woff >= ctlr.frames * 2){
			cachedwbse(b, ctlr.frames * 2 * 4);
			ringfilled(&ctlr.rg);
			ctlr.woff = 0;
		}
	}
	poperror();
	qunlock(&ctlr.lk);
	return count;
}

long
audio_ctl_write(Chan *c, void *va, long count, vlong offset)
{
	Audio_t tmp;

	USED(c); USED(offset);
	tmp = ctlr.av;
	tmp.in.flags = 0;
	tmp.out.flags = 0;
	if(!audioparse(va, count, &tmp))
		error(Ebadarg);
	if(tmp.in.flags != 0)
		error("audio: the jack has no input");
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
	if(tmp.out.flags & AUDIO_RATE_FLAG && tmp.out.rate != ctlr.av.out.rate && ctlr.running){
		pwmclock(tmp.out.rate);
		PWM(Prng1) = ctlr.range;
		PWM(Prng2) = ctlr.range;
	}
	if(tmp.out.flags & AUDIO_BUF_FLAG)
		setframes(&ctlr, framesfor(tmp.out.buf));
	tmp.out.flags = 0;
	ctlr.av = tmp;
	poperror();
	qunlock(&ctlr.lk);
	return count;
}

/* for devcons's "audio" line, and the battery */
char*
audiostatus(char *buf, char *e)
{
	return seprint(buf, e, "audio: %s rate %lud chans %lud bits %lud frames %d ahead %d played %lud underruns %lud\n",
		ctlr.running? "running" : "idle", ctlr.av.out.rate, ctlr.av.out.chan, ctlr.av.out.bits,
		ctlr.frames, ctlr.rg.ahead, ctlr.played, ctlr.underruns);
}
